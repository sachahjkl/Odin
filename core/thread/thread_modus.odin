#+build modus
#+private
package thread

import "base:intrinsics"
import "base:runtime"
import "core:strings"
import "core:sync"
import "core:sys/modus"

_IS_SUPPORTED :: true

_MODUS_THREAD_NAME_CAPACITY :: 64
_MODUS_REAPER_CAPACITY :: modus.THREAD_CAPACITY * 2

Thread_Os_Specific :: struct {
	handle:    modus.Handle,
	stack:     rawptr,
	start_ok:  sync.Sema,
	done_word: u32,
	name_buf:  [_MODUS_THREAD_NAME_CAPACITY]u8,
	name_len:  int,
}

@(private="file")
_Detached_Cleanup :: struct {
	handle: modus.Handle,
	stack:  rawptr,
}

@(private="file")
_reaper_lock: modus.Lock
@(private="file")
_reaper_entries: [_MODUS_REAPER_CAPACITY]_Detached_Cleanup

@(private="file")
_thread_names: [modus.THREAD_CAPACITY][_MODUS_THREAD_NAME_CAPACITY]u8
@(private="file")
_thread_name_lens: [modus.THREAD_CAPACITY]int

@(private="file")
_reaper_drain_locked :: proc "contextless" (skip_handle: modus.Handle = 0) {
	for &entry in _reaper_entries {
		if entry.handle == 0 || entry.handle == skip_handle {
			continue
		}
		state, st := modus.thread_state(entry.handle)
		if st != .Succeeded || state == .Stopped {
			if entry.stack != nil {
				_ = modus.memory_unmap(entry.stack)
			}
			modus.handle_close(entry.handle)
			entry = {}
		}
	}
}

@(private="file")
_reaper_drain :: proc "contextless" () {
	modus.lock(&_reaper_lock)
	_reaper_drain_locked()
	modus.unlock(&_reaper_lock)
}

@(private="file")
_reaper_enqueue :: proc "contextless" (handle: modus.Handle, stack: rawptr) {
	if handle == 0 {
		return
	}
	modus.lock(&_reaper_lock)
	_reaper_drain_locked(handle)
	for &entry in _reaper_entries {
		if entry.handle == 0 {
			entry = {handle = handle, stack = stack}
			break
		}
	}
	modus.unlock(&_reaper_lock)
}

@(fini)
_fini_thread_reaper :: proc "contextless" () {
	_reaper_drain()
}

_create :: proc(procedure: Thread_Proc, priority: Thread_Priority, name: Maybe(string)) -> ^Thread {
	_ = priority
	_reaper_drain()

	__modus_thread_entry_proc :: proc "c" (param: rawptr) -> ! {
		t := (^Thread)(param)
		sync.atomic_store(&t.id, sync.current_thread_id())

		for (.Started not_in sync.atomic_load(&t.flags)) {
			sync.wait(&t.start_ok)
		}

		{
			init_context := t.init_context
			context = _select_context_for_thread(init_context)
			defer {
				_maybe_destroy_default_temp_allocator(init_context)
				runtime.run_thread_local_cleaners()
			}

			_set_name(t)
			t.procedure(t)
		}

		slot := u32(modus.thread_record().number) & (modus.THREAD_CAPACITY - 1)
		sync.atomic_store(&_thread_name_lens[slot], 0)

		sync.atomic_or(&t.flags, {.Done})

		if .Self_Cleanup in sync.atomic_load(&t.flags) {
			handle := t.handle
			stack := t.stack
			t.handle = 0
			t.stack = nil
			context = runtime.default_context()
			free(t, t.creation_allocator)
			// Keep handle alive until thread_stop completes; another thread
			// or @(fini) reaps both the stack mapping and the handle once Stopped.
			_reaper_enqueue(handle, stack)
		} else {
			intrinsics.atomic_store_explicit(&t.done_word, 1, .Release)
			_ = modus.word_wake(&t.done_word, max(u64))
		}

		_ = modus.thread_stop(0)
		for {}
	}

	t := new(Thread)
	if t == nil {
		return nil
	}
	t.creation_allocator = context.allocator
	t.procedure = procedure
	t.name = name

	stack_mem, mem_st := modus.memory_create(modus.THREAD_STACK_PAGES)
	if mem_st != .Succeeded {
		free(t, t.creation_allocator)
		return nil
	}
	stack_addr, map_st := modus.memory_map(stack_mem, {.Write})
	modus.handle_close(stack_mem)
	if map_st != .Succeeded {
		free(t, t.creation_allocator)
		return nil
	}
	t.stack = stack_addr

	stack_top := uintptr(stack_addr) + modus.THREAD_STACK_PAGES * modus.PAGE_SIZE
	handle, th_st := modus.thread_create(__modus_thread_entry_proc, stack_top, t)
	if th_st != .Succeeded {
		_ = modus.memory_unmap(stack_addr)
		free(t, t.creation_allocator)
		return nil
	}
	t.handle = handle
	return t
}

_start :: proc(t: ^Thread) {
	sync.atomic_or(&t.flags, {.Started})
	sync.post(&t.start_ok)
}

_is_done :: proc(t: ^Thread) -> bool {
	return .Done in sync.atomic_load(&t.flags)
}

_join :: proc(t: ^Thread) {
	if t == nil || sync.atomic_load(&t.id) == sync.current_thread_id() {
		return
	}
	if .Joined in sync.atomic_or(&t.flags, {.Joined}) {
		return
	}
	if .Started not_in sync.atomic_load(&t.flags) {
		_start(t)
	}

	for intrinsics.atomic_load_explicit(&t.done_word, .Acquire) == 0 {
		_ = modus.word_wait(&t.done_word, 0)
	}

	if t.handle != 0 {
		for {
			ev := intrinsics.volatile_load(&modus.thread_record().events)
			state, st := modus.thread_state(t.handle)
			if st != .Succeeded || state == .Stopped {
				break
			}
			_ = modus.word_wait(&modus.thread_record().events, ev)
		}
		modus.handle_close(t.handle)
		t.handle = 0
	}

	if t.stack != nil {
		_ = modus.memory_unmap(t.stack)
		t.stack = nil
	}
}

_join_multiple :: proc(threads: ..^Thread) {
	for t in threads {
		_join(t)
	}
}

_destroy :: proc(t: ^Thread) {
	_join(t)
	free(t, t.creation_allocator)
}

_terminate :: proc(t: ^Thread, exit_code: int) {
	_ = exit_code
	if t == nil {
		return
	}
	if t.handle != 0 {
		_ = modus.thread_stop(t.handle)
	}
	sync.atomic_or(&t.flags, {.Done})
	intrinsics.atomic_store_explicit(&t.done_word, 1, .Release)
	_ = modus.word_wake(&t.done_word, max(u64))
}

_yield :: proc() {
	_ = modus.system_enter(0)
}

_get_name :: proc(thread: ^Thread, allocator: runtime.Allocator, loc: runtime.Source_Code_Location) -> (name: string, err: runtime.Allocator_Error) {
	if thread == nil {
		slot := u32(modus.thread_record().number) & (modus.THREAD_CAPACITY - 1)
		n := sync.atomic_load(&_thread_name_lens[slot])
		return strings.clone(string(_thread_names[slot][:n]), allocator, loc)
	}
	return strings.clone(string(thread.name_buf[:thread.name_len]), allocator, loc)
}

_set_name :: proc(thread: ^Thread) {
	name, ok := thread.name.?
	if !ok {
		return
	}
	n := min(len(name), _MODUS_THREAD_NAME_CAPACITY)
	copy(thread.name_buf[:n], name[:n])
	thread.name_len = n
	if sync.atomic_load(&thread.id) == sync.current_thread_id() {
		slot := u32(modus.thread_record().number) & (modus.THREAD_CAPACITY - 1)
		copy(_thread_names[slot][:n], name[:n])
		sync.atomic_store(&_thread_name_lens[slot], n)
	}
}
