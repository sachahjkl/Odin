#+private
#+build modus
package mem_virtual

import "core:sys/modus"

@(private="file")
RESERVATION_INLINE_CAPACITY :: 64
@(private="file")
RESERVATION_OVERFLOW_RESERVE_PAGES :: 1024 // 4 MiB uncommitted address range; committed one page at a time past the inline array.
@(private="file")
COMMIT_CHUNK_PAGES :: modus.COMMIT_CHUNK_PAGES // 512 pages per Memory_Commit / Memory_Protect chunk.

@(private="file")
Reservation_Entry :: struct {
	base:           uintptr,
	reserved_pages: u64,
	handle:         modus.Handle,
}

@(private="file")
Reservation_Registry :: struct {
	lock:                     modus.Lock,
	inline_entries:           [RESERVATION_INLINE_CAPACITY]Reservation_Entry,
	overflow_handle:          modus.Handle,
	overflow_entries:         [^]Reservation_Entry,
	overflow_reserved_pages:  u64,
	overflow_committed_pages: u64,
	overflow_len:             int,
	overflow_moves:           u64,
}

@(private="file")
_registry: Reservation_Registry

@(private="file")
_registry_overflow_grow :: proc "contextless" (reg: ^Reservation_Registry) -> bool {
	if reg.overflow_handle == 0 {
		h, st := modus.memory_create(RESERVATION_OVERFLOW_RESERVE_PAGES, flags = {.Uncommitted})
		if st != .Succeeded {
			return false
		}
		addr, map_st := modus.memory_map(h, {.Write})
		if map_st != .Succeeded {
			modus.handle_close(h)
			return false
		}
		reg.overflow_handle = h
		reg.overflow_entries = ([^]Reservation_Entry)(addr)
		reg.overflow_reserved_pages = RESERVATION_OVERFLOW_RESERVE_PAGES
		reg.overflow_committed_pages = 0
		reg.overflow_len = 0
	}
	next_index := reg.overflow_len
	needed_bytes := u64(next_index + 1) * size_of(Reservation_Entry)
	needed_pages := (needed_bytes + modus.PAGE_SIZE - 1) / modus.PAGE_SIZE
	if needed_pages > reg.overflow_reserved_pages {
		return false
	}
	if needed_pages > reg.overflow_committed_pages {
		rng := [1]modus.Page_Range{{first = reg.overflow_committed_pages, page_count = needed_pages - reg.overflow_committed_pages}}
		if _, st := modus.memory_commit(reg.overflow_handle, rng[:]); st != .Succeeded {
			return false
		}
		reg.overflow_committed_pages = needed_pages
	}
	reg.overflow_len += 1
	return true
}

@(private="file")
_registry_insert_locked :: proc "contextless" (reg: ^Reservation_Registry, entry: Reservation_Entry) -> bool {
	for &slot in reg.inline_entries {
		if slot.handle == 0 {
			slot = entry
			return true
		}
	}
	for i in 0 ..< reg.overflow_len {
		if reg.overflow_entries[i].handle == 0 {
			reg.overflow_entries[i] = entry
			reg.overflow_moves += 1
			return true
		}
	}
	if !_registry_overflow_grow(reg) {
		return false
	}
	reg.overflow_entries[reg.overflow_len - 1] = entry
	reg.overflow_moves += 1
	return true
}

@(private="file")
_registry_find_containing_locked :: proc "contextless" (reg: ^Reservation_Registry, addr: uintptr) -> (entry: Reservation_Entry, found: bool) {
	for slot in reg.inline_entries {
		if slot.handle != 0 && addr >= slot.base && addr < slot.base + uintptr(slot.reserved_pages * modus.PAGE_SIZE) {
			return slot, true
		}
	}
	for i in 0 ..< reg.overflow_len {
		slot := reg.overflow_entries[i]
		if slot.handle != 0 && addr >= slot.base && addr < slot.base + uintptr(slot.reserved_pages * modus.PAGE_SIZE) {
			return slot, true
		}
	}
	return {}, false
}

@(private="file")
_registry_remove_locked :: proc "contextless" (reg: ^Reservation_Registry, addr: uintptr) -> (entry: Reservation_Entry, found: bool) {
	for &slot in reg.inline_entries {
		if slot.handle != 0 && slot.base == addr {
			entry = slot
			slot = {}
			return entry, true
		}
	}
	for i in 0 ..< reg.overflow_len {
		slot := &reg.overflow_entries[i]
		if slot.handle != 0 && slot.base == addr {
			entry = slot^
			slot^ = {}
			return entry, true
		}
	}
	return {}, false
}

_reserve :: proc "contextless" (size: uint, address_hint: uintptr) -> (data: []byte, err: Allocator_Error) {
	if size == 0 {
		return nil, nil
	}
	if u64(size) > max(u64) - modus.PAGE_SIZE {
		return nil, .Out_Of_Memory
	}
	pages := (u64(size) + modus.PAGE_SIZE - 1) / modus.PAGE_SIZE
	if pages == 0 || pages > modus.MEMORY_PAGE_LIMIT {
		return nil, .Out_Of_Memory
	}

	mem, st := modus.memory_create(pages, flags = {.Uncommitted})
	if st != .Succeeded {
		return nil, .Out_Of_Memory
	}

	addr: rawptr
	map_st := modus.Call_Outcome.Argument_Refused
	if address_hint != 0 {
		aligned := u64(address_hint) & ~u64(modus.PAGE_SIZE - 1)
		if aligned >= modus.PAGE_SIZE && aligned < modus.USER_END {
			addr, map_st = modus.memory_map(mem, {.Write}, address = aligned)
		}
	}
	if map_st != .Succeeded {
		addr, map_st = modus.memory_map(mem, {.Write}, address = 0)
	}
	if map_st != .Succeeded {
		modus.handle_close(mem)
		return nil, .Out_Of_Memory
	}

	modus.lock(&_registry.lock)
	inserted := _registry_insert_locked(&_registry, {
		base           = uintptr(addr),
		reserved_pages = pages,
		handle         = mem,
	})
	modus.unlock(&_registry.lock)

	if !inserted {
		modus.memory_unmap(addr)
		modus.handle_close(mem)
		return nil, .Out_Of_Memory
	}

	return ([^]byte)(addr)[:pages * modus.PAGE_SIZE], nil
}

_commit :: proc "contextless" (data: rawptr, size: uint) -> Allocator_Error {
	if data == nil || size == 0 {
		return nil
	}
	start := uintptr(data)
	if u64(size) > max(u64) - modus.PAGE_SIZE {
		return .Invalid_Argument
	}

	modus.lock(&_registry.lock)
	defer modus.unlock(&_registry.lock)

	entry, ok := _registry_find_containing_locked(&_registry, start)
	if !ok {
		return .Invalid_Pointer
	}

	offset := u64(start - entry.base)
	first_page := offset / modus.PAGE_SIZE
	end_bytes := offset + u64(size)
	if end_bytes < offset {
		return .Invalid_Argument
	}
	end_page := (end_bytes + modus.PAGE_SIZE - 1) / modus.PAGE_SIZE
	if end_page > entry.reserved_pages {
		return .Out_Of_Memory
	}

	page := first_page
	for page < end_page {
		chunk := min(end_page - page, COMMIT_CHUNK_PAGES)
		rng := [1]modus.Page_Range{{first = page, page_count = chunk}}
		if _, st := modus.memory_commit(entry.handle, rng[:]); st != .Succeeded {
			// Roll back chunks committed earlier in this call.
			rollback := first_page
			for rollback < page {
				rb_chunk := min(page - rollback, COMMIT_CHUNK_PAGES)
				rb_rng := [1]modus.Page_Range{{first = rollback, page_count = rb_chunk}}
				_, _ = modus.memory_decommit(entry.handle, rb_rng[:])
				rollback += rb_chunk
			}
			return .Out_Of_Memory
		}
		page += chunk
	}
	return nil
}

_decommit :: proc "contextless" (data: rawptr, size: uint) {
	if data == nil || size == 0 {
		return
	}
	start := uintptr(data)

	modus.lock(&_registry.lock)
	defer modus.unlock(&_registry.lock)

	entry, ok := _registry_find_containing_locked(&_registry, start)
	if !ok {
		return
	}

	offset := u64(start - entry.base)
	first_page := offset / modus.PAGE_SIZE
	end_bytes := offset + u64(size)
	if end_bytes < offset {
		return
	}
	end_page := min((end_bytes + modus.PAGE_SIZE - 1) / modus.PAGE_SIZE, entry.reserved_pages)

	page := first_page
	for page < end_page {
		chunk := min(end_page - page, COMMIT_CHUNK_PAGES)
		rng := [1]modus.Page_Range{{first = page, page_count = chunk}}
		_, _ = modus.memory_decommit(entry.handle, rng[:])
		page += chunk
	}
}

_release :: proc "contextless" (data: rawptr, size: uint) {
	_ = size
	if data == nil {
		return
	}
	modus.lock(&_registry.lock)
	entry, ok := _registry_remove_locked(&_registry, uintptr(data))
	modus.unlock(&_registry.lock)
	if !ok {
		return
	}
	_ = modus.memory_unmap(rawptr(entry.base))
	modus.handle_close(entry.handle)
}

_protect :: proc "contextless" (data: rawptr, size: uint, flags: Protect_Flags) -> bool {
	if data == nil || size == 0 {
		return false
	}
	// Modus enforces W^X: never allow writable and executable pages together.
	if .Write in flags && .Execute in flags {
		return false
	}

	map_flags: modus.Map_Flags
	switch {
	case flags == {}:
		map_flags = {.No_Access}
	case .Write in flags:
		map_flags = {.Write}
	case .Execute in flags:
		map_flags = {.Execute}
	case .Read in flags:
		map_flags = {}
	}

	aligned_start := u64(uintptr(data)) & ~u64(modus.PAGE_SIZE - 1)
	end_addr := u64(uintptr(data)) + u64(size)
	if end_addr < u64(uintptr(data)) {
		return false
	}
	total_pages := (end_addr - aligned_start + modus.PAGE_SIZE - 1) / modus.PAGE_SIZE

	whole_mapping := false
	modus.lock(&_registry.lock)
	if entry, ok := _registry_find_containing_locked(&_registry, uintptr(aligned_start)); ok {
		if uintptr(aligned_start) == entry.base && total_pages == entry.reserved_pages {
			whole_mapping = true
		}
	}
	modus.unlock(&_registry.lock)

	if whole_mapping || total_pages <= modus.RANGE_TABLE_PAGE_LIMIT {
		rng := [1]modus.Address_Range{{address = aligned_start, page_count = total_pages}}
		_, st := modus.memory_protect(rng[:], map_flags)
		return st == .Succeeded
	}

	done: u64 = 0
	for done < total_pages {
		chunk := min(total_pages - done, modus.RANGE_TABLE_PAGE_LIMIT)
		rng := [1]modus.Address_Range{{address = aligned_start + done * modus.PAGE_SIZE, page_count = chunk}}
		if _, st := modus.memory_protect(rng[:], map_flags); st != .Succeeded {
			return false
		}
		done += chunk
	}
	return true
}

_map_file :: proc "contextless" (f: any, size: i64, flags: Map_File_Flags) -> (data: []byte, error: Map_File_Error) {
	return nil, .Map_Failure
}

_unmap_file :: proc "contextless" (data: []byte) {
}
