#+build modus
#+private
package runtime

import "base:intrinsics"

// Segregated slab + large-object heap allocator backed by modus uncommitted
// memory objects. Every allocation is preceded by a 16-byte _Heap_Header so
// frees and resizes resolve in O(1) without extra page tables or alignment
// constraints from the kernel. Empty slabs are unmapped and closed immediately.

@(private="file")
_HEAP_CLASS_COUNT :: 10
@(private="file")
_HEAP_HEADER_SIZE :: 16
@(private="file")
_HEAP_SLAB_HEADER_SIZE :: 128
@(private="file")
_HEAP_SLAB_PAGES_SMALL :: 16 // 64 KiB per slab for slot sizes 32..8192
@(private="file")
_HEAP_SLAB_PAGES_LARGE :: 32 // 128 KiB per slab for slot size 16384

// Slot sizes include the 16-byte _Heap_Header; usable payload is slot_size - 16.
@(private="file", rodata)
_HEAP_SLOT_SIZES := [_HEAP_CLASS_COUNT]u64{
	32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384,
}

@(private="file")
_Heap_Header :: struct {
	// Low bit 0: pointer to owning _Heap_Slab (4 KiB aligned).
	// Low bit 1: large allocation; high bits store (u64(handle) << 1) | 1.
	tag: u64,
	// Slab allocation: class index (0 ..< _HEAP_CLASS_COUNT).
	// Large allocation: usable payload capacity in bytes.
	aux: u64,
}
#assert(size_of(_Heap_Header) == _HEAP_HEADER_SIZE)

@(private="file")
_Heap_Free_Node :: struct {
	next: ^_Heap_Free_Node,
}

@(private="file")
_Heap_Slab :: struct {
	prev:            ^_Heap_Slab,
	next:            ^_Heap_Slab,
	free_list:       ^_Heap_Free_Node,
	mem_handle:      _Modus_Handle,
	class_index:     u32,
	reserved_bytes:  u64,
	committed_pages: u64,
	bump_offset:     u64,
	used_count:      u64,
	on_partial:      bool,
}
#assert(size_of(_Heap_Slab) <= _HEAP_SLAB_HEADER_SIZE)

@(private="file")
_heap_lock: _Modus_Lock
@(private="file")
_heap_partial: [_HEAP_CLASS_COUNT]^_Heap_Slab

@(private="file")
_heap_class_for_size :: #force_inline proc "contextless" (size: u64) -> (class_index: u32, ok: bool) {
	needed := size + _HEAP_HEADER_SIZE
	for i in u32(0) ..< _HEAP_CLASS_COUNT {
		if needed <= _HEAP_SLOT_SIZES[i] {
			return i, true
		}
	}
	return 0, false
}

@(private="file")
_heap_commit_pages :: proc "contextless" (mem: _Modus_Handle, first_page, page_count: u64) -> bool {
	budget := _modus_own_budget()
	done: u64 = 0
	for done < page_count {
		chunk := min(page_count - done, _MODUS_COMMIT_CHUNK_PAGES)
		rng := [1]_Modus_Page_Range{{first = first_page + done, page_count = chunk}}
		_, status := _modus_call(
			.Memory_Commit,
			u64(mem),
			u64(budget),
			u64(uintptr(&rng[0])),
			1,
			0,
		)
		if status != .Succeeded {
			return false
		}
		done += chunk
	}
	return true
}

@(private="file")
_heap_partial_push :: proc "contextless" (class_index: u32, slab: ^_Heap_Slab) {
	if slab.on_partial {
		return
	}
	head := _heap_partial[class_index]
	slab.prev = nil
	slab.next = head
	if head != nil {
		head.prev = slab
	}
	_heap_partial[class_index] = slab
	slab.on_partial = true
}

@(private="file")
_heap_partial_remove :: proc "contextless" (class_index: u32, slab: ^_Heap_Slab) {
	if !slab.on_partial {
		return
	}
	if slab.prev != nil {
		slab.prev.next = slab.next
	} else {
		_heap_partial[class_index] = slab.next
	}
	if slab.next != nil {
		slab.next.prev = slab.prev
	}
	slab.prev = nil
	slab.next = nil
	slab.on_partial = false
}

@(private="file")
_heap_slab_create :: proc "contextless" (class_index: u32) -> ^_Heap_Slab {
	slot_size := _HEAP_SLOT_SIZES[class_index]
	slab_pages := u64(_HEAP_SLAB_PAGES_LARGE if slot_size > 8192 else _HEAP_SLAB_PAGES_SMALL)

	mem_res, mem_st := _modus_call(.Memory_Create, u64(_modus_own_budget()), slab_pages, transmute(u64)_Modus_Memory_Flags{.Uncommitted})
	if mem_st != .Succeeded {
		return nil
	}
	mem := _Modus_Handle(mem_res[0])

	map_res, map_st := _modus_call(.Memory_Map, u64(mem), 0, 0, transmute(u64)_Modus_Map_Flags{.Write}, 0, 0)
	if map_st != .Succeeded {
		_modus_call(.Handle_Close, u64(mem))
		return nil
	}
	base := rawptr(uintptr(map_res[0]))

	if !_heap_commit_pages(mem, 0, 1) {
		_modus_call(.Memory_Unmap, 0, u64(uintptr(base)))
		_modus_call(.Handle_Close, u64(mem))
		return nil
	}

	slab := (^_Heap_Slab)(base)
	slab^ = {
		mem_handle      = mem,
		class_index     = class_index,
		reserved_bytes  = slab_pages * _MODUS_PAGE_SIZE,
		committed_pages = 1,
		bump_offset     = _HEAP_SLAB_HEADER_SIZE,
	}
	_heap_partial_push(class_index, slab)
	return slab
}

@(private="file")
_heap_slab_alloc_locked :: proc "contextless" (class_index: u32, size: int, zero_memory: bool) -> rawptr {
	slot_size := _HEAP_SLOT_SIZES[class_index]
	slab := _heap_partial[class_index]
	if slab == nil {
		slab = _heap_slab_create(class_index)
		if slab == nil {
			return nil
		}
	}

	if node := slab.free_list; node != nil {
		slab.free_list = node.next
		slab.used_count += 1
		if slab.free_list == nil && slab.bump_offset + slot_size > slab.reserved_bytes {
			_heap_partial_remove(class_index, slab)
		}
		payload := rawptr(node)
		if zero_memory {
			intrinsics.mem_zero(payload, size)
		}
		return payload
	}

	if slab.bump_offset + slot_size > slab.reserved_bytes {
		_heap_partial_remove(class_index, slab)
		slab = _heap_slab_create(class_index)
		if slab == nil {
			return nil
		}
	}

	end := slab.bump_offset + slot_size
	needed_pages := (end + _MODUS_PAGE_SIZE - 1) / _MODUS_PAGE_SIZE
	if needed_pages > slab.committed_pages {
		if !_heap_commit_pages(slab.mem_handle, slab.committed_pages, needed_pages - slab.committed_pages) {
			if slab.used_count == 0 {
				_heap_partial_remove(class_index, slab)
				mem := slab.mem_handle
				_modus_call(.Memory_Unmap, 0, u64(uintptr(slab)))
				_modus_call(.Handle_Close, u64(mem))
			}
			return nil
		}
		slab.committed_pages = needed_pages
	}

	slot_addr := uintptr(slab) + uintptr(slab.bump_offset)
	slab.bump_offset = end
	slab.used_count += 1
	if slab.free_list == nil && slab.bump_offset + slot_size > slab.reserved_bytes {
		_heap_partial_remove(class_index, slab)
	}

	hdr := (^_Heap_Header)(slot_addr)
	hdr.tag = u64(uintptr(slab))
	hdr.aux = u64(class_index)
	// Newly committed kernel pages are already zero-filled.
	return rawptr(slot_addr + _HEAP_HEADER_SIZE)
}

@(private="file")
_heap_large_alloc :: proc "contextless" (size: u64) -> rawptr {
	if size > max(u64) - _HEAP_HEADER_SIZE - _MODUS_PAGE_SIZE {
		return nil
	}
	total := size + _HEAP_HEADER_SIZE
	pages := (total + _MODUS_PAGE_SIZE - 1) / _MODUS_PAGE_SIZE
	if pages == 0 || pages > _MODUS_MEMORY_PAGE_LIMIT {
		return nil
	}

	mem_res, mem_st := _modus_call(.Memory_Create, u64(_modus_own_budget()), pages, transmute(u64)_Modus_Memory_Flags{.Uncommitted})
	if mem_st != .Succeeded {
		return nil
	}
	mem := _Modus_Handle(mem_res[0])

	map_res, map_st := _modus_call(.Memory_Map, u64(mem), 0, 0, transmute(u64)_Modus_Map_Flags{.Write}, 0, 0)
	if map_st != .Succeeded {
		_modus_call(.Handle_Close, u64(mem))
		return nil
	}
	base := rawptr(uintptr(map_res[0]))

	if !_heap_commit_pages(mem, 0, pages) {
		_modus_call(.Memory_Unmap, 0, u64(uintptr(base)))
		_modus_call(.Handle_Close, u64(mem))
		return nil
	}

	hdr := (^_Heap_Header)(base)
	hdr.tag = (u64(mem) << 1) | 1
	hdr.aux = pages * _MODUS_PAGE_SIZE - _HEAP_HEADER_SIZE
	return rawptr(uintptr(base) + _HEAP_HEADER_SIZE)
}

_heap_alloc :: proc "contextless" (size: int, zero_memory := true) -> rawptr {
	if size <= 0 {
		return nil
	}
	if class_index, ok := _heap_class_for_size(u64(size)); ok {
		_modus_lock(&_heap_lock)
		ptr := _heap_slab_alloc_locked(class_index, size, zero_memory)
		_modus_unlock(&_heap_lock)
		return ptr
	}
	return _heap_large_alloc(u64(size))
}

_heap_free :: proc "contextless" (ptr: rawptr) {
	if ptr == nil {
		return
	}
	hdr := (^_Heap_Header)(uintptr(ptr) - _HEAP_HEADER_SIZE)
	tag := hdr.tag
	if tag & 1 != 0 {
		mem := _Modus_Handle(tag >> 1)
		_modus_call(.Memory_Unmap, 0, u64(uintptr(hdr)))
		_modus_call(.Handle_Close, u64(mem))
		return
	}

	slab := (^_Heap_Slab)(uintptr(tag))
	class_index := u32(hdr.aux)
	unmap_base: rawptr
	close_mem: _Modus_Handle

	_modus_lock(&_heap_lock)
	node := (^_Heap_Free_Node)(ptr)
	node.next = slab.free_list
	slab.free_list = node
	slab.used_count -= 1
	if slab.used_count == 0 {
		_heap_partial_remove(class_index, slab)
		unmap_base = rawptr(slab)
		close_mem = slab.mem_handle
	} else if !slab.on_partial {
		_heap_partial_push(class_index, slab)
	}
	_modus_unlock(&_heap_lock)

	if unmap_base != nil {
		_modus_call(.Memory_Unmap, 0, u64(uintptr(unmap_base)))
		_modus_call(.Handle_Close, u64(close_mem))
	}
}

_heap_resize :: proc "contextless" (ptr: rawptr, new_size: int) -> rawptr {
	if ptr == nil {
		return _heap_alloc(new_size, false)
	}
	if new_size <= 0 {
		_heap_free(ptr)
		return nil
	}
	hdr := (^_Heap_Header)(uintptr(ptr) - _HEAP_HEADER_SIZE)
	old_cap: u64
	if hdr.tag & 1 != 0 {
		old_cap = hdr.aux
	} else {
		old_cap = _HEAP_SLOT_SIZES[u32(hdr.aux)] - _HEAP_HEADER_SIZE
	}
	if u64(new_size) <= old_cap {
		return ptr
	}
	next := _heap_alloc(new_size, false)
	if next == nil {
		return nil
	}
	intrinsics.mem_copy_non_overlapping(next, ptr, int(old_cap))
	_heap_free(ptr)
	return next
}
