#+build modus
package modus

import "base:intrinsics"

// Fixed kernel ABI constants from modus (src/library/modus/contract/).
PAGE_SIZE :: 4096
WAIT_FOREVER :: max(u64)
THREAD_CAPACITY :: 256
THREAD_AREA_PAGES :: 4
THREAD_STACK_PAGES :: 16
MEMORY_PAGE_LIMIT :: 512 * 512
RANGE_TABLE_CAPACITY :: 256
RANGE_TABLE_PAGE_LIMIT :: 65536
COMMIT_CHUNK_PAGES :: 512
LOG_TEXT_BYTES_MOST :: 4096

PROCESS_BASE :: 0x0000_0000_0040_0000
CHOSEN_BASE :: 0x0000_1000_0000_0000
MODULE_BASE :: 0x0000_2000_0000_0000
BAND_START :: 0x0000_3000_0000_0000
SLOT :: 0x0000_0100_0000_0000
DATE_PAGE_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Date_Page)
STORAGE_FILE_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Storage_File)

TIME_ADDRESS :: 0x0000_7FFF_FFFE_0000
USER_END :: 0x0000_8000_0000_0000
THREAD_AREA_BASE :: TIME_ADDRESS - THREAD_CAPACITY * THREAD_AREA_PAGES * PAGE_SIZE
CONTEXT_ADDRESS :: THREAD_AREA_BASE - 2 * PAGE_SIZE
STACK_TOP :: CONTEXT_ADDRESS - PAGE_SIZE

#assert(THREAD_AREA_BASE == 0x0000_7FFF_FFBE_0000)
#assert(STACK_TOP == 0x0000_7FFF_FFBD_D000)
#assert(DATE_PAGE_ADDRESS == 0x0000_3600_0000_0000)
#assert(STORAGE_FILE_ADDRESS == 0x0000_3700_0000_0000)

CONTEXT_HANDLES :: 20
CONTEXT_VALUES :: 24
CONTEXT_LOG :: 14
CONTEXT_BUDGET :: 15
CONTEXT_WIRING_RING :: 16
CONTEXT_LOG_OUTPUT :: 17
CONTEXT_LOG_OUTPUT_END :: 18
CONTEXT_READY_RING :: 19

GRANT_STORAGE_RING :: 7
GRANT_STORAGE_REGION :: 8
GRANT_STORAGE_SERVICE :: 9
CONTEXT_VALUE_STORAGE_FILE_SIZE :: 18
CONTEXT_VALUE_SEED :: 9
CONTEXT_VALUE_SEED_COUNT :: 4
CONTEXT_VALUE_FIXED_RANGES_MAPPED :: 20

RING_CAPACITY :: 32
RING_PAGE_COUNT :: 2
RING_CAPACITY_LIMIT :: 1 << 16
ROOT_COMMAND_READY :: u32(40)
READY_ANSWER_BOUND_MILLISECONDS :: u64(60_000)
STORAGE_ANSWER_BOUND_MILLISECONDS :: u64(120_000)
FAULT_RECORD_CAPACITY :: 16
DATE_MILLISECONDS_LIMIT :: i64(253402300800) * 1000
DATE_READ_TRIES :: 64

Handle :: distinct u32

Right :: enum u32 {
	Give     = 0,
	Read     = 1,
	Write    = 2,
	Execute  = 3,
	Control  = 4,
	Inspect  = 5,
	Devices  = 6,
	Stop     = 7,
	Spend    = 8,
	Physical = 9,
	Schedule = 10,
	Commit   = 11,
	Events   = 12,
	Debug    = 13,
	Counters = 14,
}
Rights :: bit_set[Right; u32]

Object_Kind :: enum u8 {
	None      = 0,
	Memory    = 1,
	Process   = 2,
	Interrupt = 3,
	Ports     = 4,
	Machine   = 5,
	Thread    = 6,
	Budget    = 7,
	Log       = 8,
}

Operation :: enum u32 {
	None              = 0,
	Log               = 1,
	Memory_Create     = 2,
	Memory_Map        = 3,
	Memory_Unmap      = 4,
	Memory_Size       = 5,
	Process_Create    = 6,
	Process_Start     = 7,
	Process_Stop      = 8,
	Process_State     = 9,
	Handle_Give       = 10,
	Handle_Close      = 11,
	Interrupt_Read    = 12,
	Device_Create     = 13,
	Inspect           = 14,
	Machine_Stop      = 15,
	Thread_Create     = 16,
	Thread_Stop       = 17,
	Thread_State      = 18,
	Word_Wait         = 19,
	Word_Wake         = 20,
	Budget_Create     = 21,
	Budget_Read       = 22,
	Handle_State      = 23,
	Handle_Revoke     = 24,
	Memory_Physical   = 25,
	Process_Module    = 26,
	Strategy_Set      = 27,
	Memory_Commit     = 28,
	Memory_Protect    = 29,
	Fault_Handler_Set = 30,
	Fault_Answer      = 31,
	Events_Set        = 32,
	Thread_Control    = 33,
	Guest_Run         = 34,
	Log_Read          = 35,
	Memory_Read       = 36,
}

Call_Outcome :: enum u64 {
	Succeeded                        = 0,
	Argument_Refused                 = 1,
	Nothing_Has_That_Name            = 2,
	Name_Already_Taken               = 3,
	Grant_Or_Right_Missing           = 4,
	Callee_Busy                      = 5,
	Budget_Or_Capacity_Exhausted     = 6,
	Wrong_State                      = 7,
	Another_Change_Came_First        = 8,
	Operation_Unsupported            = 9,
	Data_Damaged                     = 10,
	Callee_Unavailable               = 11,
	Stopped_After_A_Partial_Change   = 12,
	Callee_Stopped_During_The_Call   = 13,
	Connection_Ended_During_The_Call = 14,
	Deadline_Passed_During_The_Call  = 15,
	Answer_Unreadable                = 16,
}

Stop_Outcome :: enum u32 {
	None               = 0,
	Done               = 1,
	Failed             = 2,
	Refused            = 3,
	Stopped_On_Request = 4,
}

Process_State :: enum u32 {
	None    = 0,
	Created = 1,
	Ready   = 2,
	Waiting = 3,
	Stopped = 4,
}

Log_Level :: enum u8 {
	Info    = 0,
	Debug   = 1,
	Warning = 2,
	Error   = 3,
}

Memory_Flag :: enum u64 {
	Frames_Now  = 0,
	Contiguous  = 1,
	Uncommitted = 2,
}
Memory_Flags :: bit_set[Memory_Flag; u64]

Commit_Flag :: enum u64 {
	Decommit   = 0,
	Frames_Now = 1,
}
Commit_Flags :: bit_set[Commit_Flag; u64]

Map_Flag :: enum u64 {
	Write           = 0,
	Execute         = 1,
	No_Access       = 2,
	Receive_Handles = 3,
	At_Address_Zero = 4,
	Write_Combining = 5,
}
Map_Flags :: bit_set[Map_Flag; u64]

Fixed_Range :: enum u8 {
	Module_Files       = 0,
	Settings_Page      = 2,
	Presentation_Page  = 3,
	Plan_Values_Page   = 4,
	Date_Page          = 6,
	Storage_File       = 7,
	Module_Tables      = 8,
	Debug_Image        = 11,
	Disk_Process_Page  = 12,
	Fresh_Bytes_Page   = 15,
	Start_Policy_Pages = 16,
	Edit_Target_Page   = 17,
}
Fixed_Ranges :: bit_set[Fixed_Range; u64]
#assert(size_of(Fixed_Ranges) == size_of(u64))

Time_Record :: struct {
	milliseconds:    u64,
	cycle_frequency: u64,
	cycle_start:     u64,
}
#assert(size_of(Time_Record) == 24)

Date_Page :: struct {
	change_count:              u32,
	source:                    u32,
	milliseconds_at_time_zero: i64,
	zone_offset_seconds:       i64,
}
#assert(size_of(Date_Page) == 24)

Fault_Record :: struct {
	thread:      u64,
	serial:      u64,
	address:     u64,
	access:      u64,
	instruction: u64,
	kind:        u64,
	error_code:  u64,
	reserved:    u64,
}
#assert(size_of(Fault_Record) == 64)

Thread_Record :: struct {
	self:            u64,
	parameter:       u64,
	number:          u64,
	events:          u32,
	processors:      u32,
	fault_written:   u32,
	fault_read:      u32,
	fault_full:      u32,
	wait_room_words: u32,
	fault_records:   [FAULT_RECORD_CAPACITY]Fault_Record,
}
#assert(size_of(Thread_Record) <= PAGE_SIZE)
#assert(offset_of(Thread_Record, number) == 16)
#assert(offset_of(Thread_Record, events) == 24)
#assert(offset_of(Thread_Record, processors) == 28)

Context :: struct {
	handles: [CONTEXT_HANDLES]Handle,
	values:  [CONTEXT_VALUES]u64,
}
#assert(size_of(Context) == 272)
#assert(offset_of(Context, values) == 80)

Word :: struct {
	address: u64,
	value:   u64,
}
#assert(size_of(Word) == 16)

Page_Range :: struct {
	first:      u64,
	page_count: u64,
}
#assert(size_of(Page_Range) == 16)

Address_Range :: struct {
	address:    u64,
	page_count: u64,
}
#assert(size_of(Address_Range) == 16)

Error_Record :: struct {
	kind:      i64,
	unit:      i64,
	operation: i64,
	argument:  i64,
	value:     i64,
	limit:     i64,
	found:     i64,
}
#assert(size_of(Error_Record) == 56)

Ring_Record :: struct {
	kind:   u32,
	tag:    u32,
	values: [7]u64,
}
#assert(size_of(Ring_Record) == 64)

Ring_Counters :: struct {
	write:        u32,
	writer_waits: u32,
	reserved_0:   [56]u8,
	read:         u32,
	reader_waits: u32,
	reserved_1:   [56]u8,
}
#assert(size_of(Ring_Counters) == 128)

Ring_Head :: struct {
	commands:    Ring_Counters,
	reserved_0:  [PAGE_SIZE / 2 - size_of(Ring_Counters)]u8,
	completions: Ring_Counters,
	reserved_1:  [PAGE_SIZE / 2 - size_of(Ring_Counters)]u8,
}
#assert(size_of(Ring_Head) == PAGE_SIZE)

Ring_Queue :: struct {
	counters: ^Ring_Counters,
	records:  [^]Ring_Record,
	mask:     u32,
}

Ring :: struct {
	head:        ^Ring_Head,
	commands:    Ring_Queue,
	completions: Ring_Queue,
}

foreign _ {
	system_enter  :: proc "c" (wait: u64) -> u64 ---
	thread_record :: proc "c" () -> ^Thread_Record ---
}

context_record :: #force_inline proc "contextless" () -> ^Context {
	return (^Context)(uintptr(CONTEXT_ADDRESS))
}

own_budget :: #force_inline proc "contextless" () -> Handle {
	return context_record().handles[CONTEXT_BUDGET]
}

ranges_mapped :: proc "contextless" (values: ^[CONTEXT_VALUES]u64) -> Fixed_Ranges {
	word := values[CONTEXT_VALUE_FIXED_RANGES_MAPPED]
	members: u64
	for member in Fixed_Range {
		members |= u64(1) << uint(member)
	}
	if word & ~members != 0 {
		return {}
	}
	return transmute(Fixed_Ranges)word
}

ring_open :: proc "contextless" (memory: rawptr, page_count: u64) -> (r: Ring, ok: bool) {
	if memory == nil || page_count < RING_PAGE_COUNT || page_count - 1 > RING_CAPACITY_LIMIT / RING_CAPACITY {
		return {}, false
	}
	cap := (page_count - 1) * RING_CAPACITY
	if cap > RING_CAPACITY_LIMIT || cap & (cap - 1) != 0 {
		return {}, false
	}
	head := (^Ring_Head)(memory)
	records := ([^]Ring_Record)(uintptr(memory) + PAGE_SIZE)
	return {
		head        = head,
		commands    = {counters = &head.commands, records = records, mask = u32(cap) - 1},
		completions = {counters = &head.completions, records = records[cap:], mask = u32(cap) - 1},
	}, true
}

kernel_ring :: #force_inline proc "contextless" () -> Ring {
	r, _ := ring_open(rawptr(uintptr(thread_record()) + PAGE_SIZE), RING_PAGE_COUNT)
	return r
}

ring_empty :: #force_inline proc "contextless" (q: ^Ring_Queue) -> bool {
	return intrinsics.atomic_load_explicit(&q.counters.write, .Relaxed) == intrinsics.atomic_load_explicit(&q.counters.read, .Relaxed)
}

ring_push :: proc "contextless" (q: ^Ring_Queue, rec: Ring_Record) -> bool {
	write := intrinsics.atomic_load_explicit(&q.counters.write, .Relaxed)
	if write - intrinsics.atomic_load_explicit(&q.counters.read, .Acquire) > q.mask {
		return false
	}
	q.records[write & q.mask] = rec
	intrinsics.atomic_store_explicit(&q.counters.write, write + 1, .Release)
	return true
}

ring_pop :: proc "contextless" (q: ^Ring_Queue) -> (rec: Ring_Record, ok: bool) {
	read := intrinsics.atomic_load_explicit(&q.counters.read, .Relaxed)
	write := intrinsics.atomic_load_explicit(&q.counters.write, .Acquire)
	if write == read || write - read > q.mask + 1 {
		return {}, false
	}
	rec = q.records[read & q.mask]
	intrinsics.atomic_store_explicit(&q.counters.read, read + 1, .Release)
	return rec, true
}

ring_complete :: #force_inline proc "contextless" (counter: ^u32) {
	intrinsics.atomic_store_explicit(counter, intrinsics.volatile_load(counter), .Seq_Cst)
}

@(private="file")
_cmd_tag: u32

call :: proc "contextless" (op: Operation, values: ..u64) -> (results: [7]u64, status: Call_Outcome) {
	kr := kernel_ring()
	if !ring_empty(&kr.commands) || !ring_empty(&kr.completions) {
		return {}, .Callee_Busy
	}
	tag := intrinsics.atomic_add(&_cmd_tag, 1) + 1
	cmd := Ring_Record{kind = u32(op), tag = tag}
	for v, i in values {
		if i < len(cmd.values) {
			cmd.values[i] = v
		}
	}
	if !ring_push(&kr.commands, cmd) {
		return {}, .Callee_Busy
	}
	system_enter(0)
	comp, ok := ring_pop(&kr.completions)
	if !ok || comp.tag != tag {
		return {}, .Answer_Unreadable
	}
	if comp.kind != 0 {
		if comp.kind <= u32(max(Call_Outcome)) {
			return {}, Call_Outcome(comp.kind)
		}
		return {}, .Answer_Unreadable
	}
	return comp.values, .Succeeded
}

time_milliseconds :: #force_inline proc "contextless" () -> u64 {
	record := (^Time_Record)(uintptr(TIME_ADDRESS))
	return intrinsics.volatile_load(&record.milliseconds)
}

nanoseconds :: proc "contextless" () -> u64 {
	record := (^Time_Record)(uintptr(TIME_ADDRESS))
	freq := record.cycle_frequency
	if freq == 0 {
		return intrinsics.volatile_load(&record.milliseconds) * 1_000_000
	}
	tsc := u64(intrinsics.read_cycle_counter())
	start := record.cycle_start
	passed := tsc - start if tsc > start else 0
	return passed / freq * 1_000_000_000 + u64(u128(passed % freq) * 1_000_000_000 / u128(freq))
}

word_wait :: proc "contextless" (word: ^u32, expected: u32, deadline: u64 = WAIT_FOREVER) -> u64 {
	kr := kernel_ring()
	if !ring_empty(&kr.commands) || !ring_empty(&kr.completions) {
		return time_milliseconds()
	}
	w := Word{address = u64(uintptr(word)), value = u64(expected)}
	tag := intrinsics.atomic_add(&_cmd_tag, 1) + 1
	cmd := Ring_Record{
		kind   = u32(Operation.Word_Wait),
		tag    = tag,
		values = {0 = u64(uintptr(&w)), 1 = 1},
	}
	if !ring_push(&kr.commands, cmd) {
		return time_milliseconds()
	}
	now := system_enter(max(deadline, 1))
	_, _ = ring_pop(&kr.completions)
	return now
}

word_wait_many :: proc "contextless" (words: []Word, deadline: u64 = WAIT_FOREVER) -> u64 {
	if len(words) == 0 {
		return system_enter(max(deadline, 1))
	}
	kr := kernel_ring()
	if !ring_empty(&kr.commands) || !ring_empty(&kr.completions) {
		return time_milliseconds()
	}
	tag := intrinsics.atomic_add(&_cmd_tag, 1) + 1
	cmd := Ring_Record{
		kind   = u32(Operation.Word_Wait),
		tag    = tag,
		values = {0 = u64(uintptr(raw_data(words))), 1 = u64(len(words))},
	}
	if !ring_push(&kr.commands, cmd) {
		return time_milliseconds()
	}
	now := system_enter(max(deadline, 1))
	_, _ = ring_pop(&kr.completions)
	return now
}

word_wake :: proc "contextless" (word: ^u32, count: u64 = 1) -> u64 {
	res, status := call(.Word_Wake, u64(uintptr(word)), count)
	if status != .Succeeded {
		return 0
	}
	return res[0]
}

Lock :: struct {
	state: u32,
}

lock :: proc "contextless" (l: ^Lock) {
	if _, ok := intrinsics.atomic_compare_exchange_strong(&l.state, 0, 1); ok {
		return
	}
	for intrinsics.atomic_exchange(&l.state, 2) != 0 {
		word_wait(&l.state, 2)
	}
}

unlock :: proc "contextless" (l: ^Lock) {
	if intrinsics.atomic_exchange(&l.state, 0) == 2 {
		word_wake(&l.state, 1)
	}
}

ring_send :: proc "contextless" (q: ^Ring_Queue, rec: Ring_Record) -> bool {
	if !ring_push(q, rec) {
		return false
	}
	ring_complete(&q.counters.write)
	if intrinsics.atomic_exchange(&q.counters.reader_waits, 0) != 0 {
		word_wake(&q.counters.write, max(u64))
	}
	return true
}

ring_receive :: proc "contextless" (q: ^Ring_Queue) -> (rec: Ring_Record, ok: bool) {
	rec, ok = ring_pop(q)
	if ok {
		ring_complete(&q.counters.read)
		if intrinsics.atomic_exchange(&q.counters.writer_waits, 0) != 0 {
			word_wake(&q.counters.read, max(u64))
		}
	}
	return
}

memory_create :: proc "contextless" (page_count: u64, budget: Handle = 0, flags: Memory_Flags = {}) -> (memory: Handle, status: Call_Outcome) {
	res: [7]u64
	res, status = call(.Memory_Create, u64(budget == 0 ? own_budget() : budget), page_count, transmute(u64)flags)
	return Handle(res[0]), status
}

memory_map :: proc "contextless" (memory: Handle, flags: Map_Flags = {.Write}, process: Handle = 0, address: u64 = 0, first: u64 = 0, page_count: u64 = 0) -> (result: rawptr, status: Call_Outcome) {
	res: [7]u64
	res, status = call(.Memory_Map, u64(memory), u64(process), address, transmute(u64)flags, first, page_count)
	return rawptr(uintptr(res[0])), status
}

memory_unmap :: proc "contextless" (address: rawptr, process: Handle = 0) -> Call_Outcome {
	_, status := call(.Memory_Unmap, u64(process), u64(uintptr(address)))
	return status
}

memory_size :: proc "contextless" (memory: Handle) -> (pages: u64, status: Call_Outcome) {
	res: [7]u64
	res, status = call(.Memory_Size, u64(memory))
	return res[0], status
}

memory_commit :: proc "contextless" (memory: Handle, ranges: []Page_Range, budget: Handle = 0) -> (changed: u64, status: Call_Outcome) {
	res: [7]u64
	res, status = call(.Memory_Commit, u64(memory), u64(budget == 0 ? own_budget() : budget), u64(uintptr(raw_data(ranges))), u64(len(ranges)), 0)
	return res[0], status
}

memory_decommit :: proc "contextless" (memory: Handle, ranges: []Page_Range) -> (changed: u64, status: Call_Outcome) {
	res: [7]u64
	res, status = call(.Memory_Commit, u64(memory), 0, u64(uintptr(raw_data(ranges))), u64(len(ranges)), transmute(u64)Commit_Flags{.Decommit})
	return res[0], status
}

memory_protect :: proc "contextless" (ranges: []Address_Range, flags: Map_Flags, process: Handle = 0) -> (changed: u64, status: Call_Outcome) {
	res: [7]u64
	res, status = call(.Memory_Protect, u64(uintptr(raw_data(ranges))), u64(len(ranges)), transmute(u64)flags, u64(process))
	return res[0], status
}

handle_state :: proc "contextless" (handle: Handle, memory: Handle = 0) -> (kind: Object_Kind, rights: Rights, through: bool) {
	res, status := call(.Handle_State, u64(handle), u64(memory))
	if status != .Succeeded || res[0] > u64(max(Object_Kind)) {
		return .None, {}, false
	}
	return Object_Kind(res[0]), transmute(Rights)u32(res[1]), res[2] != 0
}

handle_close :: proc "contextless" (handle: Handle) {
	if handle != 0 {
		call(.Handle_Close, u64(handle))
	}
}

process_state :: proc "contextless" (process: Handle) -> (state: Process_State, status: Call_Outcome) {
	res: [7]u64
	res, status = call(.Process_State, u64(process), 0)
	if status != .Succeeded || res[0] > u64(max(Process_State)) {
		return .None, status
	}
	return Process_State(res[0]), status
}

thread_create :: proc "contextless" (entry: proc "c" (rawptr) -> !, stack_top: uintptr, parameter: rawptr, budget: Handle = 0, weight: u64 = 0, request: u64 = 0) -> (handle: Handle, status: Call_Outcome) {
	res: [7]u64
	res, status = call(.Thread_Create, u64(budget == 0 ? own_budget() : budget), u64(uintptr(rawptr(entry))), u64(stack_top), u64(uintptr(parameter)), weight, request)
	return Handle(res[0]), status
}

thread_stop :: proc "contextless" (thread: Handle = 0) -> Call_Outcome {
	_, status := call(.Thread_Stop, u64(thread))
	return status
}

thread_state :: proc "contextless" (thread: Handle) -> (state: Process_State, status: Call_Outcome) {
	res: [7]u64
	res, status = call(.Thread_State, u64(thread))
	if status != .Succeeded || res[0] > u64(max(Process_State)) {
		return .None, status
	}
	return Process_State(res[0]), status
}

log_write :: proc "contextless" (level: Log_Level, text: []u8) -> Call_Outcome {
	log_handle := context_record().handles[CONTEXT_LOG]
	if log_handle == 0 {
		return .Succeeded
	}
	if len(text) == 0 {
		empty: u8
		_, status := call(.Log, u64(log_handle), u64(uintptr(&empty)), 0, u64(level), 0, 0)
		return status
	}
	off := 0
	for off < len(text) {
		chunk := min(len(text) - off, LOG_TEXT_BYTES_MOST)
		_, status := call(.Log, u64(log_handle), u64(uintptr(&text[off])), u64(chunk), u64(level), 0, 0)
		if status != .Succeeded {
			return status
		}
		off += chunk
	}
	return .Succeeded
}
