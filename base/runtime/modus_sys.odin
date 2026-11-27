#+private
#+build modus
package runtime

import "base:intrinsics"

_MODUS_PAGE_SIZE :: 4096
_MODUS_WAIT_FOREVER :: max(u64)
_MODUS_THREAD_CAPACITY :: 256
_MODUS_THREAD_AREA_PAGES :: 4
_MODUS_TIME_ADDRESS :: 0x0000_7FFF_FFFE_0000
_MODUS_THREAD_AREA_BASE :: _MODUS_TIME_ADDRESS - _MODUS_THREAD_CAPACITY * _MODUS_THREAD_AREA_PAGES * _MODUS_PAGE_SIZE
_MODUS_CONTEXT_ADDRESS :: _MODUS_THREAD_AREA_BASE - 2 * _MODUS_PAGE_SIZE
_MODUS_CONTEXT_HANDLES :: 20
_MODUS_CONTEXT_VALUES :: 24
_MODUS_CONTEXT_LOG :: 14
_MODUS_CONTEXT_BUDGET :: 15
_MODUS_CONTEXT_READY_RING :: 19
_MODUS_CONTEXT_VALUE_SEED :: 9
_MODUS_CONTEXT_VALUE_SEED_COUNT :: 4
_MODUS_LOG_TEXT_BYTES_MOST :: 4096
_MODUS_MEMORY_PAGE_LIMIT :: 512 * 512
_MODUS_COMMIT_CHUNK_PAGES :: 512
_MODUS_RING_CAPACITY :: 32
_MODUS_RING_PAGE_COUNT :: 2
_MODUS_RING_CAPACITY_LIMIT :: 1 << 16
_MODUS_ROOT_COMMAND_READY :: u32(40)
_MODUS_READY_ANSWER_BOUND_MILLISECONDS :: u64(60_000)

_Modus_Handle :: distinct u32

_Modus_Operation :: enum u32 {
	None          = 0,
	Log           = 1,
	Memory_Create = 2,
	Memory_Map    = 3,
	Memory_Unmap  = 4,
	Memory_Size   = 5,
	Process_Stop  = 8,
	Handle_Close  = 11,
	Word_Wait     = 19,
	Word_Wake     = 20,
	Memory_Commit = 28,
}

_Modus_Call_Outcome :: enum u64 {
	Succeeded                    = 0,
	Argument_Refused             = 1,
	Nothing_Has_That_Name        = 2,
	Name_Already_Taken           = 3,
	Grant_Or_Right_Missing       = 4,
	Callee_Busy                  = 5,
	Budget_Or_Capacity_Exhausted = 6,
	Wrong_State                  = 7,
	Another_Change_Came_First    = 8,
	Operation_Unsupported        = 9,
	Data_Damaged                 = 10,
	Callee_Unavailable           = 11,
	Stopped_After_A_Partial_Change   = 12,
	Callee_Stopped_During_The_Call   = 13,
	Connection_Ended_During_The_Call = 14,
	Deadline_Passed_During_The_Call  = 15,
	Answer_Unreadable            = 16,
}

_Modus_Stop_Outcome :: enum u32 {
	None               = 0,
	Done               = 1,
	Failed             = 2,
	Refused            = 3,
	Stopped_On_Request = 4,
}

_Modus_Log_Level :: enum u8 {
	Info    = 0,
	Debug   = 1,
	Warning = 2,
	Error   = 3,
}

_Modus_Memory_Flag :: enum u64 {
	Frames_Now  = 0,
	Contiguous  = 1,
	Uncommitted = 2,
}
_Modus_Memory_Flags :: bit_set[_Modus_Memory_Flag; u64]

_Modus_Map_Flag :: enum u64 {
	Write           = 0,
	Execute         = 1,
	No_Access       = 2,
	Receive_Handles = 3,
	At_Address_Zero = 4,
	Write_Combining = 5,
}
_Modus_Map_Flags :: bit_set[_Modus_Map_Flag; u64]

_Modus_Commit_Flag :: enum u64 {
	Decommit   = 0,
	Frames_Now = 1,
}
_Modus_Commit_Flags :: bit_set[_Modus_Commit_Flag; u64]

_Modus_Time_Record :: struct {
	milliseconds:    u64,
	cycle_frequency: u64,
	cycle_start:     u64,
}

_Modus_Fault_Record :: struct {
	thread:      u64,
	serial:      u64,
	address:     u64,
	access:      u64,
	instruction: u64,
	kind:        u64,
	error_code:  u64,
	reserved:    u64,
}
#assert(size_of(_Modus_Fault_Record) == 64)

_Modus_Thread_Record :: struct {
	self:            u64,
	parameter:       u64,
	number:          u64,
	events:          u32,
	processors:      u32,
	fault_written:   u32,
	fault_read:      u32,
	fault_full:      u32,
	wait_room_words: u32,
	fault_records:   [16]_Modus_Fault_Record,
}
#assert(size_of(_Modus_Thread_Record) <= _MODUS_PAGE_SIZE)

_Modus_Context :: struct {
	handles: [_MODUS_CONTEXT_HANDLES]_Modus_Handle,
	values:  [_MODUS_CONTEXT_VALUES]u64,
}
#assert(size_of(_Modus_Context) == 272)

_Modus_Word :: struct {
	address: u64,
	value:   u64,
}

_Modus_Page_Range :: struct {
	first:      u64,
	page_count: u64,
}

_Modus_Ring_Record :: struct {
	kind:   u32,
	tag:    u32,
	values: [7]u64,
}
#assert(size_of(_Modus_Ring_Record) == 64)

_Modus_Ring_Counters :: struct {
	write:        u32,
	writer_waits: u32,
	reserved_0:   [56]u8,
	read:         u32,
	reader_waits: u32,
	reserved_1:   [56]u8,
}
#assert(size_of(_Modus_Ring_Counters) == 128)

_Modus_Ring_Head :: struct {
	commands:    _Modus_Ring_Counters,
	reserved_0:  [_MODUS_PAGE_SIZE / 2 - size_of(_Modus_Ring_Counters)]u8,
	completions: _Modus_Ring_Counters,
	reserved_1:  [_MODUS_PAGE_SIZE / 2 - size_of(_Modus_Ring_Counters)]u8,
}
#assert(size_of(_Modus_Ring_Head) == _MODUS_PAGE_SIZE)

_Modus_Ring_Queue :: struct {
	counters: ^_Modus_Ring_Counters,
	records:  [^]_Modus_Ring_Record,
	mask:     u32,
}

_Modus_Ring :: struct {
	head:        ^_Modus_Ring_Head,
	commands:    _Modus_Ring_Queue,
	completions: _Modus_Ring_Queue,
}

foreign _ {
	@(link_name="system_enter")
	_modus_system_enter :: proc "c" (wait: u64) -> u64 ---
	@(link_name="thread_record")
	_modus_thread_record :: proc "c" () -> ^_Modus_Thread_Record ---
}

_modus_context_record :: #force_inline proc "contextless" () -> ^_Modus_Context {
	return (^_Modus_Context)(uintptr(_MODUS_CONTEXT_ADDRESS))
}

_modus_own_budget :: #force_inline proc "contextless" () -> _Modus_Handle {
	return _modus_context_record().handles[_MODUS_CONTEXT_BUDGET]
}

_modus_thread_index :: #force_inline proc "contextless" () -> u64 {
	return _modus_thread_record().number & (_MODUS_THREAD_CAPACITY - 1)
}

_modus_time_milliseconds :: #force_inline proc "contextless" () -> u64 {
	record := (^_Modus_Time_Record)(uintptr(_MODUS_TIME_ADDRESS))
	return intrinsics.volatile_load(&record.milliseconds)
}

_modus_ring_open :: proc "contextless" (memory: rawptr, page_count: u64) -> (r: _Modus_Ring, ok: bool) {
	if memory == nil || page_count < _MODUS_RING_PAGE_COUNT || page_count - 1 > _MODUS_RING_CAPACITY_LIMIT / _MODUS_RING_CAPACITY {
		return {}, false
	}
	cap := (page_count - 1) * _MODUS_RING_CAPACITY
	if cap > _MODUS_RING_CAPACITY_LIMIT || cap & (cap - 1) != 0 {
		return {}, false
	}
	head := (^_Modus_Ring_Head)(memory)
	records := ([^]_Modus_Ring_Record)(uintptr(memory) + _MODUS_PAGE_SIZE)
	return {
		head        = head,
		commands    = {counters = &head.commands, records = records, mask = u32(cap) - 1},
		completions = {counters = &head.completions, records = records[cap:], mask = u32(cap) - 1},
	}, true
}

_modus_kernel_ring :: #force_inline proc "contextless" () -> _Modus_Ring {
	r, _ := _modus_ring_open(rawptr(uintptr(_modus_thread_record()) + _MODUS_PAGE_SIZE), _MODUS_RING_PAGE_COUNT)
	return r
}

_modus_ring_empty :: #force_inline proc "contextless" (q: ^_Modus_Ring_Queue) -> bool {
	return intrinsics.atomic_load_explicit(&q.counters.write, .Relaxed) == intrinsics.atomic_load_explicit(&q.counters.read, .Relaxed)
}

_modus_ring_push :: proc "contextless" (q: ^_Modus_Ring_Queue, rec: _Modus_Ring_Record) -> bool {
	write := intrinsics.atomic_load_explicit(&q.counters.write, .Relaxed)
	if write - intrinsics.atomic_load_explicit(&q.counters.read, .Acquire) > q.mask {
		return false
	}
	q.records[write & q.mask] = rec
	intrinsics.atomic_store_explicit(&q.counters.write, write + 1, .Release)
	return true
}

_modus_ring_pop :: proc "contextless" (q: ^_Modus_Ring_Queue) -> (rec: _Modus_Ring_Record, ok: bool) {
	read := intrinsics.atomic_load_explicit(&q.counters.read, .Relaxed)
	write := intrinsics.atomic_load_explicit(&q.counters.write, .Acquire)
	if write == read || write - read > q.mask + 1 {
		return {}, false
	}
	rec = q.records[read & q.mask]
	intrinsics.atomic_store_explicit(&q.counters.read, read + 1, .Release)
	return rec, true
}

_modus_ring_complete :: #force_inline proc "contextless" (counter: ^u32) {
	intrinsics.atomic_store_explicit(counter, intrinsics.volatile_load(counter), .Seq_Cst)
}

@(private="file")
_modus_cmd_tag: u32

_modus_call :: proc "contextless" (op: _Modus_Operation, values: ..u64) -> (results: [7]u64, status: _Modus_Call_Outcome) {
	kr := _modus_kernel_ring()
	if !_modus_ring_empty(&kr.commands) || !_modus_ring_empty(&kr.completions) {
		return {}, .Callee_Busy
	}
	tag := intrinsics.atomic_add(&_modus_cmd_tag, 1) + 1
	cmd := _Modus_Ring_Record{kind = u32(op), tag = tag}
	for v, i in values {
		if i < len(cmd.values) {
			cmd.values[i] = v
		}
	}
	if !_modus_ring_push(&kr.commands, cmd) {
		return {}, .Callee_Busy
	}
	_modus_system_enter(0)
	comp, ok := _modus_ring_pop(&kr.completions)
	if !ok || comp.tag != tag {
		return {}, .Answer_Unreadable
	}
	if comp.kind != 0 {
		if comp.kind <= u32(max(_Modus_Call_Outcome)) {
			return {}, _Modus_Call_Outcome(comp.kind)
		}
		return {}, .Answer_Unreadable
	}
	return comp.values, .Succeeded
}

_modus_word_wait :: proc "contextless" (word: ^u32, expected: u32, deadline: u64 = _MODUS_WAIT_FOREVER) -> u64 {
	kr := _modus_kernel_ring()
	if !_modus_ring_empty(&kr.commands) || !_modus_ring_empty(&kr.completions) {
		return _modus_time_milliseconds()
	}
	w := _Modus_Word{address = u64(uintptr(word)), value = u64(expected)}
	tag := intrinsics.atomic_add(&_modus_cmd_tag, 1) + 1
	cmd := _Modus_Ring_Record{
		kind   = u32(_Modus_Operation.Word_Wait),
		tag    = tag,
		values = {0 = u64(uintptr(&w)), 1 = 1},
	}
	if !_modus_ring_push(&kr.commands, cmd) {
		return _modus_time_milliseconds()
	}
	now := _modus_system_enter(max(deadline, 1))
	_, _ = _modus_ring_pop(&kr.completions)
	return now
}

_modus_word_wait_many :: proc "contextless" (words: []_Modus_Word, deadline: u64 = _MODUS_WAIT_FOREVER) -> u64 {
	if len(words) == 0 {
		return _modus_system_enter(max(deadline, 1))
	}
	kr := _modus_kernel_ring()
	if !_modus_ring_empty(&kr.commands) || !_modus_ring_empty(&kr.completions) {
		return _modus_time_milliseconds()
	}
	tag := intrinsics.atomic_add(&_modus_cmd_tag, 1) + 1
	cmd := _Modus_Ring_Record{
		kind   = u32(_Modus_Operation.Word_Wait),
		tag    = tag,
		values = {0 = u64(uintptr(raw_data(words))), 1 = u64(len(words))},
	}
	if !_modus_ring_push(&kr.commands, cmd) {
		return _modus_time_milliseconds()
	}
	now := _modus_system_enter(max(deadline, 1))
	_, _ = _modus_ring_pop(&kr.completions)
	return now
}

_modus_word_wake :: proc "contextless" (word: ^u32, count: u64 = 1) -> u64 {
	res, status := _modus_call(.Word_Wake, u64(uintptr(word)), count)
	if status != .Succeeded {
		return 0
	}
	return res[0]
}

_Modus_Lock :: struct {
	state: u32,
}

_modus_lock :: proc "contextless" (l: ^_Modus_Lock) {
	if _, ok := intrinsics.atomic_compare_exchange_strong(&l.state, 0, 1); ok {
		return
	}
	for intrinsics.atomic_exchange(&l.state, 2) != 0 {
		_modus_word_wait(&l.state, 2)
	}
}

_modus_unlock :: proc "contextless" (l: ^_Modus_Lock) {
	if intrinsics.atomic_exchange(&l.state, 0) == 2 {
		_modus_word_wake(&l.state, 1)
	}
}

_modus_ring_send :: proc "contextless" (q: ^_Modus_Ring_Queue, rec: _Modus_Ring_Record) -> bool {
	if !_modus_ring_push(q, rec) {
		return false
	}
	_modus_ring_complete(&q.counters.write)
	if intrinsics.atomic_exchange(&q.counters.reader_waits, 0) != 0 {
		_modus_word_wake(&q.counters.write, max(u64))
	}
	return true
}

_modus_ring_receive :: proc "contextless" (q: ^_Modus_Ring_Queue) -> (rec: _Modus_Ring_Record, ok: bool) {
	rec, ok = _modus_ring_pop(q)
	if ok {
		_modus_ring_complete(&q.counters.read)
		if intrinsics.atomic_exchange(&q.counters.writer_waits, 0) != 0 {
			_modus_word_wake(&q.counters.read, max(u64))
		}
	}
	return
}

_modus_ready_at_end :: proc "contextless" () {
	ctx := _modus_context_record()
	memory := intrinsics.atomic_exchange(&ctx.handles[_MODUS_CONTEXT_READY_RING], 0)
	if memory == 0 {
		return
	}
	defer _modus_call(.Handle_Close, u64(memory))

	sz_res, sz_st := _modus_call(.Memory_Size, u64(memory))
	if sz_st != .Succeeded {
		return
	}
	map_res, map_st := _modus_call(.Memory_Map, u64(memory), 0, 0, transmute(u64)_Modus_Map_Flags{.Write}, 0, 0)
	if map_st != .Succeeded {
		return
	}
	addr := rawptr(uintptr(map_res[0]))
	defer _modus_call(.Memory_Unmap, 0, u64(uintptr(addr)))

	mapped, open_ok := _modus_ring_open(addr, sz_res[0])
	if !open_ok {
		return
	}
	if !_modus_ring_send(&mapped.commands, _Modus_Ring_Record{kind = _MODUS_ROOT_COMMAND_READY}) {
		return
	}
	now := _modus_time_milliseconds()
	deadline := now > _MODUS_WAIT_FOREVER - _MODUS_READY_ANSWER_BOUND_MILLISECONDS ? _MODUS_WAIT_FOREVER : now + _MODUS_READY_ANSWER_BOUND_MILLISECONDS
	for {
		if _, answered := _modus_ring_receive(&mapped.completions); answered {
			return
		}
		write_val := intrinsics.atomic_load_explicit(&mapped.completions.counters.write, .Acquire)
		intrinsics.atomic_store_explicit(&mapped.completions.counters.reader_waits, 1, .Release)
		_modus_ring_complete(&mapped.completions.counters.reader_waits)
		if _, answered := _modus_ring_receive(&mapped.completions); answered {
			intrinsics.atomic_store_explicit(&mapped.completions.counters.reader_waits, 0, .Release)
			return
		}
		// Wait on both write counter and reader_waits == 1 so a wake that
		// cleared reader_waits before entry ends the wait immediately.
		words := [2]_Modus_Word{
			{address = u64(uintptr(&mapped.completions.counters.write)), value = u64(write_val)},
			{address = u64(uintptr(&mapped.completions.counters.reader_waits)), value = 1},
		}
		returned := _modus_word_wait_many(words[:], deadline)
		intrinsics.atomic_store_explicit(&mapped.completions.counters.reader_waits, 0, .Release)
		if returned >= deadline {
			return
		}
	}
}
