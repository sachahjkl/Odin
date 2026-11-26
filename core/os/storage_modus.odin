#+private
#+build modus
package os

import "base:intrinsics"
import "core:sync"
import "core:sys/modus"

// Lazy mutex-serialized client for the modus private storage service.
// Connects via Context.handles[7, 8, 9] and Context.values[3] at STORAGE_FILE_ADDRESS.

_Storage_Place :: distinct i64
_STORAGE_ROOT :: _Storage_Place(0)

_STORAGE_ENTRY_OBJECT :: i64(1)
_STORAGE_ENTRY_TREE :: i64(2)
_STORAGE_NESTING_LIMIT :: 32
_STORAGE_NAME_LIMIT :: 255

_Storage_Add_Row :: struct {
	name_offset: i64,
	name_count:  i64,
	kind:        i64,
}

_Storage_Listed :: struct {
	name_offset: i64,
	name_count:  i64,
	kind:        i64,
	size:        i64,
	generation:  i64,
}

// Module format v8 binary headers (src/library/modus/contract/module/format.odin).
@(private="file")
_MOD_MAGIC :: u64(0x0000_454C_5544_4F4D)
@(private="file")
_MOD_VERSION :: u32(8)
@(private="file")
_MOD_MACHINE_X86_64 :: u32(1)
@(private="file")
_MOD_PARAM_CAPACITY :: 12
@(private="file")
_MOD_TABLE_EXPORTS :: u32(4)
@(private="file")
_MOD_TABLE_FUNCTIONS :: u32(6)
@(private="file")
_MOD_TABLE_STRINGS :: u32(7)
@(private="file")
_MOD_TABLE_RECORDS :: u32(9)

@(private="file")
_Mod_Header :: struct {
	magic:           u64,
	version:         u32,
	header_size:     u32,
	must_understand: u64,
	machine:         u32,
	table_count:     u32,
	memory_size:     u64,
	entry_export:    u32,
	category:        u8,
	reserved:        u8,
	tags:            u16,
}
#assert(size_of(_Mod_Header) == 48)

@(private="file")
_Mod_Table_Entry :: struct {
	offset:      u64,
	count:       u32,
	record_size: u32,
}
#assert(size_of(_Mod_Table_Entry) == 16)

@(private="file")
_Mod_Export :: struct {
	code_offset: u64,
	function:    u32,
	reserved:    u32,
}
#assert(size_of(_Mod_Export) == 16)

@(private="file")
_Mod_Function :: struct {
	name_offset:           u32,
	name_count:            u32,
	about_offset:          u32,
	about_count:           u32,
	parameter_names:       [_MOD_PARAM_CAPACITY]u32,
	parameter_count:       u8,
	result:                u8,
	parameters:            [_MOD_PARAM_CAPACITY]u8,
	parameter_name_counts: [_MOD_PARAM_CAPACITY]u8,
	parameter_directions:  [_MOD_PARAM_CAPACITY]u8,
	parameter_needs:       [_MOD_PARAM_CAPACITY]u8,
	reserved:              u16,
	text_offset:           u32,
	text_count:            u32,
	parameter_details:     [_MOD_PARAM_CAPACITY]u32,
	result_detail:         u32,
	error_record:          u32,
}
#assert(size_of(_Mod_Function) == 180)

@(private="file")
_Mod_Record :: struct {
	name_offset: u32,
	name_count:  u32,
	size:        u32,
	first_field: u32,
	field_count: u32,
	reserved:    u32,
}
#assert(size_of(_Mod_Record) == 24)

@(private="file")
_Iso_Slice :: struct {
	start: u64,
	count: u64,
}
#assert(size_of(_Iso_Slice) == 16)

@(private="file")
_Iso_Table_Field :: struct {
	start:         u64,
	count:         u64,
	capacity:      u64,
	memory_handle: u64,
}
#assert(size_of(_Iso_Table_Field) == 32)

@(private="file")
_Iso_Arg :: struct {
	integer:      u64,
	text:         []u8,
	table_bytes:  []u8,
	table_count:  u64,
	region_start: u64,
	field_offset: u64,
}

_Modus_Storage_Client :: struct {
	opened:        bool,
	gone:          bool,
	ring_memory:   modus.Handle,
	region_memory: modus.Handle,
	service:       modus.Handle,
	calls:         modus.Ring,
	region:        []u8,
	file:          []u8,
	tag:           u32,
	late_tag:      u32,
}

g_storage_mutex: sync.Mutex
g_storage: _Modus_Storage_Client

@(private="file")
_mod_read :: proc "contextless" (file: []u8, offset: u64, $T: typeid, size := u64(size_of(T))) -> (val: T, ok: bool) {
	count := min(size, size_of(T))
	if offset > u64(len(file)) || count > u64(len(file)) - offset {
		return {}, false
	}
	intrinsics.mem_copy_non_overlapping(&val, raw_data(file[offset:]), int(count))
	return val, true
}

@(private="file")
_mod_header :: proc "contextless" (file: []u8) -> (h: _Mod_Header, ok: bool) {
	h = _mod_read(file, 0, _Mod_Header) or_return
	if h.magic != _MOD_MAGIC || h.version != _MOD_VERSION || h.must_understand != 0 || h.machine != _MOD_MACHINE_X86_64 {
		return {}, false
	}
	return h, true
}

@(private="file")
_mod_table :: proc "contextless" (file: []u8, kind: u32) -> (e: _Mod_Table_Entry, ok: bool) {
	h := _mod_header(file) or_return
	if kind >= h.table_count {
		return {}, false
	}
	return _mod_read(file, u64(h.header_size) + u64(kind) * size_of(_Mod_Table_Entry), _Mod_Table_Entry)
}

@(private="file")
_mod_record :: proc "contextless" (file: []u8, kind: u32, index: u32, $T: typeid) -> (val: T, ok: bool) {
	e := _mod_table(file, kind) or_return
	if index >= e.count || e.record_size == 0 {
		return {}, false
	}
	return _mod_read(file, e.offset + u64(index) * u64(e.record_size), T, u64(e.record_size))
}

@(private="file")
_mod_string :: proc "contextless" (file: []u8, offset, count: u32) -> string {
	e, ok := _mod_table(file, _MOD_TABLE_STRINGS)
	if !ok || u64(offset) > u64(e.count) || u64(count) > u64(e.count) - u64(offset) {
		return ""
	}
	start := e.offset + u64(offset)
	if start > u64(len(file)) || u64(count) > u64(len(file)) - start {
		return ""
	}
	return string(file[start:][:count])
}

@(private="file")
_mod_find_export :: proc "contextless" (file: []u8, name: string) -> (export_index: u32, fn: _Mod_Function, ok: bool) {
	h := _mod_header(file) or_return
	exports := _mod_table(file, _MOD_TABLE_EXPORTS) or_return
	for idx in u32(1) ..< exports.count {
		if idx == h.entry_export {
			continue
		}
		ex := _mod_record(file, _MOD_TABLE_EXPORTS, idx, _Mod_Export) or_continue
		cand := _mod_record(file, _MOD_TABLE_FUNCTIONS, ex.function, _Mod_Function) or_continue
		if _mod_string(file, cand.name_offset, cand.name_count) == name {
			return idx, cand, true
		}
	}
	return 0, {}, false
}

@(private="file")
_iso_store :: proc "contextless" (region: []u8, offset: u64, val: $T) {
	v := val
	intrinsics.mem_copy_non_overlapping(raw_data(region[offset:]), &v, size_of(T))
}

@(private="file")
_iso_load :: proc "contextless" (region: []u8, offset: u64, $T: typeid) -> (val: T) {
	intrinsics.mem_copy_non_overlapping(&val, raw_data(region[offset:]), size_of(T))
	return
}

@(private="file")
_iso_field_size :: proc "contextless" (type_word: u8) -> u64 {
	switch type_word {
	case 1, 3, 4, 7: // Integer, Record, Handle, Enum
		return 8
	case 2: // Text
		return size_of(_Iso_Slice)
	case 5, 6: // Table, Bytes
		return size_of(_Iso_Table_Field)
	}
	return 0
}

@(private="file")
_storage_connected :: proc "contextless" (c: ^_Modus_Storage_Client) -> bool {
	if c.gone {
		return false
	}
	k1, _, _ := modus.handle_state(c.ring_memory)
	k2, _, _ := modus.handle_state(c.region_memory)
	st, _ := modus.process_state(c.service)
	if k1 != .Memory || k2 != .Memory || st == .Stopped || st == .None {
		c.gone = true
	}
	return !c.gone
}

@(private="file")
_storage_wait_ready :: proc "contextless" (c: ^_Modus_Storage_Client) -> bool {
	now := modus.time_milliseconds()
	deadline := modus.WAIT_FOREVER if now > modus.WAIT_FOREVER - modus.STORAGE_ANSWER_BOUND_MILLISECONDS else now + modus.STORAGE_ANSWER_BOUND_MILLISECONDS
	for {
		ev := intrinsics.volatile_load(&modus.thread_record().events)
		st, _ := modus.process_state(c.service)
		if comp, has := modus.ring_receive(&c.calls.completions); has {
			return comp.tag == 0 && comp.kind == 0
		}
		if st == .Stopped || st == .None || modus.time_milliseconds() >= deadline {
			return false
		}
		w := intrinsics.atomic_load_explicit(&c.calls.completions.counters.write, .Acquire)
		intrinsics.atomic_store_explicit(&c.calls.completions.counters.reader_waits, 1, .Release)
		modus.ring_complete(&c.calls.completions.counters.reader_waits)
		if comp, has := modus.ring_receive(&c.calls.completions); has {
			intrinsics.atomic_store_explicit(&c.calls.completions.counters.reader_waits, 0, .Release)
			return comp.tag == 0 && comp.kind == 0
		}
		words := [3]modus.Word{
			{address = u64(uintptr(&modus.thread_record().events)), value = u64(ev)},
			{address = u64(uintptr(&c.calls.completions.counters.write)), value = u64(w)},
			{address = u64(uintptr(&c.calls.completions.counters.reader_waits)), value = 1},
		}
		returned := modus.word_wait_many(words[:], deadline)
		intrinsics.atomic_store_explicit(&c.calls.completions.counters.reader_waits, 0, .Release)
		if returned >= deadline {
			return false
		}
	}
}

@(private="file")
_storage_wait_late_locked :: proc(c: ^_Modus_Storage_Client) -> Error {
	if c.late_tag == 0 {
		return nil
	}
	now := modus.time_milliseconds()
	deadline := modus.WAIT_FOREVER if now > modus.WAIT_FOREVER - modus.STORAGE_ANSWER_BOUND_MILLISECONDS else now + modus.STORAGE_ANSWER_BOUND_MILLISECONDS
	for {
		ev := intrinsics.volatile_load(&modus.thread_record().events)
		for _ in 0 ..< modus.RING_CAPACITY {
			rec, has := modus.ring_receive(&c.calls.completions)
			if !has {
				break
			}
			if rec.tag == c.late_tag {
				c.late_tag = 0
				return nil
			}
		}
		if !_storage_connected(c) {
			return .Permission_Denied
		}
		if modus.time_milliseconds() >= deadline {
			return .Timeout
		}
		w := intrinsics.atomic_load_explicit(&c.calls.completions.counters.write, .Acquire)
		intrinsics.atomic_store_explicit(&c.calls.completions.counters.reader_waits, 1, .Release)
		modus.ring_complete(&c.calls.completions.counters.reader_waits)
		for _ in 0 ..< modus.RING_CAPACITY {
			rec, has := modus.ring_receive(&c.calls.completions)
			if !has {
				break
			}
			if rec.tag == c.late_tag {
				intrinsics.atomic_store_explicit(&c.calls.completions.counters.reader_waits, 0, .Release)
				c.late_tag = 0
				return nil
			}
		}
		words := [3]modus.Word{
			{address = u64(uintptr(&modus.thread_record().events)), value = u64(ev)},
			{address = u64(uintptr(&c.calls.completions.counters.write)), value = u64(w)},
			{address = u64(uintptr(&c.calls.completions.counters.reader_waits)), value = 1},
		}
		returned := modus.word_wait_many(words[:], deadline)
		intrinsics.atomic_store_explicit(&c.calls.completions.counters.reader_waits, 0, .Release)
		if returned >= deadline {
			for _ in 0 ..< modus.RING_CAPACITY {
				rec, has := modus.ring_receive(&c.calls.completions)
				if !has {
					break
				}
				if rec.tag == c.late_tag {
					c.late_tag = 0
					return nil
				}
			}
			return .Timeout
		}
	}
}

_storage_ensure_open_locked :: proc() -> (^_Modus_Storage_Client, Error) {
	if g_storage.opened {
		if !_storage_connected(&g_storage) {
			return nil, .Permission_Denied
		}
		return &g_storage, nil
	}

	ctx := modus.context_record()
	ring_h := ctx.handles[modus.GRANT_STORAGE_RING]
	region_h := ctx.handles[modus.GRANT_STORAGE_REGION]
	svc_h := ctx.handles[modus.GRANT_STORAGE_SERVICE]
	file_size := ctx.values[modus.CONTEXT_VALUE_STORAGE_FILE_SIZE]
	if ring_h == 0 || region_h == 0 || file_size == 0 {
		return nil, .Permission_Denied
	}

	ring_pages, ring_sz_st := modus.memory_size(ring_h)
	if ring_sz_st != .Succeeded {
		return nil, .Permission_Denied
	}
	region_pages, reg_sz_st := modus.memory_size(region_h)
	if reg_sz_st != .Succeeded {
		return nil, .Permission_Denied
	}

	ring_addr, ring_map_st := modus.memory_map(ring_h, {.Write, .Receive_Handles})
	if ring_map_st != .Succeeded {
		return nil, .Permission_Denied
	}
	calls, ring_ok := modus.ring_open(ring_addr, ring_pages)
	if !ring_ok {
		_ = modus.memory_unmap(ring_addr)
		return nil, .Permission_Denied
	}

	reg_addr, reg_map_st := modus.memory_map(region_h, {.Write})
	if reg_map_st != .Succeeded {
		_ = modus.memory_unmap(ring_addr)
		return nil, .Permission_Denied
	}

	file_base := ([^]u8)(uintptr(modus.STORAGE_FILE_ADDRESS))
	file := file_base[:file_size]
	if _, hdr_ok := _mod_header(file); !hdr_ok {
		_ = modus.memory_unmap(ring_addr)
		_ = modus.memory_unmap(reg_addr)
		return nil, .Permission_Denied
	}

	g_storage = {
		opened        = true,
		ring_memory   = ring_h,
		region_memory = region_h,
		service       = svc_h,
		calls         = calls,
		region        = ([^]u8)(reg_addr)[:region_pages * modus.PAGE_SIZE],
		file          = file,
	}

	if !_storage_wait_ready(&g_storage) {
		_ = modus.memory_unmap(ring_addr)
		_ = modus.memory_unmap(reg_addr)
		g_storage = {}
		return nil, .Permission_Denied
	}

	return &g_storage, nil
}

_storage_call_locked :: proc(c: ^_Modus_Storage_Client, name: string, args: []_Iso_Arg) -> (val: i64, text: []u8, err: Error) {
	if !_storage_connected(c) {
		return 0, nil, .Permission_Denied
	}
	if c.late_tag != 0 {
		_storage_wait_late_locked(c) or_return
	}
	export_idx, fn, found := _mod_find_export(c.file, name)
	if !found || len(args) != int(fn.parameter_count) {
		return 0, nil, .Unsupported
	}

	// Compute argument record size.
	rec_size: u64 = 0
	for i in 0 ..< int(fn.parameter_count) {
		fsz := _iso_field_size(fn.parameters[i])
		if fsz == 0 {
			return 0, nil, .Unsupported
		}
		if fn.parameter_needs[i] == 1 {
			rec_size += 8
		}
		rec_size += fsz
	}
	switch fn.result {
	case 0, 1, 7: // None, Integer, Enum
	case 2, 5:    // Text, Table
		rec_size += size_of(_Iso_Slice)
	case 3:       // Record
		rec_size += 8
	case:
		return 0, nil, .Unsupported
	}
	if rec_size > u64(len(c.region)) {
		return 0, nil, .Out_Of_Memory
	}

	field: u64 = 0
	next := rec_size
	for i in 0 ..< int(fn.parameter_count) {
		if fn.parameter_needs[i] == 1 {
			_iso_store(c.region, field, u64(1)) // Presence.Given
			field += 8
		}
		args[i].field_offset = field
		t := fn.parameters[i]
		switch t {
		case 1, 4, 7: // Integer, Handle, Enum
			_iso_store(c.region, field, args[i].integer)
		case 2: // Text
			b := args[i].text
			if u64(len(b)) > u64(len(c.region)) - next {
				return 0, nil, .Out_Of_Memory
			}
			if len(b) > 0 {
				intrinsics.mem_copy_non_overlapping(raw_data(c.region[next:]), raw_data(b), len(b))
			}
			_iso_store(c.region, field, _Iso_Slice{start = next, count = u64(len(b))})
			next += u64(len(b))
		case 5, 6: // Table, Bytes
			elem_size: u64 = 1
			if t == 5 {
				rec, rec_ok := _mod_record(c.file, _MOD_TABLE_RECORDS, fn.parameter_details[i], _Mod_Record)
				if !rec_ok || rec.size == 0 {
					return 0, nil, .Unsupported
				}
				elem_size = u64(rec.size)
			}
			cap_recs := u64(len(args[i].table_bytes)) / elem_size
			dir := fn.parameter_directions[i] // 0=Read, 1=Change, 2=Append
			start := (next + 7) &~ u64(7)
			in_region := cap_recs - min(args[i].table_count, cap_recs) if dir == 2 else args[i].table_count
			if start > u64(len(c.region)) || in_region > (u64(len(c.region)) - start) / elem_size {
				return 0, nil, .Out_Of_Memory
			}
			if dir != 2 && in_region > 0 {
				intrinsics.mem_copy_non_overlapping(raw_data(c.region[start:]), raw_data(args[i].table_bytes), int(in_region * elem_size))
			}
			args[i].region_start = start
			_iso_store(c.region, field, _Iso_Table_Field{start = start, count = args[i].table_count, capacity = cap_recs})
			next = start + in_region * elem_size
		case:
			return 0, nil, .Unsupported
		}
		field += _iso_field_size(t)
	}

	res_slice: _Iso_Slice
	switch fn.result {
	case 2: // Text
		res_slice = {start = next, count = u64(len(c.region)) - next}
		_iso_store(c.region, field, res_slice)
	case 5: // Table
		rec, rec_ok := _mod_record(c.file, _MOD_TABLE_RECORDS, fn.result_detail, _Mod_Record)
		next = (next + 7) &~ u64(7)
		if !rec_ok || rec.size == 0 || next > u64(len(c.region)) {
			return 0, nil, .Unsupported
		}
		res_slice = {start = next, count = (u64(len(c.region)) - next) / u64(rec.size)}
		_iso_store(c.region, field, res_slice)
	case 3: // Record
		rec, rec_ok := _mod_record(c.file, _MOD_TABLE_RECORDS, fn.result_detail, _Mod_Record)
		next = (next + 7) &~ u64(7)
		if !rec_ok || next > u64(len(c.region)) || u64(rec.size) > u64(len(c.region)) - next {
			return 0, nil, .Out_Of_Memory
		}
		res_slice = {start = next, count = u64(rec.size)}
		intrinsics.mem_zero(raw_data(c.region[next:]), int(rec.size))
		_iso_store(c.region, field, next)
	}

	c.tag += 1
	if c.tag == 0 {
		c.tag = 1
	}
	tag := c.tag
	if !modus.ring_send(&c.calls.commands, modus.Ring_Record{kind = export_idx, tag = tag, values = {0 = 0, 1 = rec_size}}) {
		return 0, nil, Platform_Error(modus.Call_Outcome.Callee_Busy)
	}

	now := modus.time_milliseconds()
	deadline := modus.WAIT_FOREVER if now > modus.WAIT_FOREVER - modus.STORAGE_ANSWER_BOUND_MILLISECONDS else now + modus.STORAGE_ANSWER_BOUND_MILLISECONDS
	comp: modus.Ring_Record
	answered := false
	for !answered {
		ev := intrinsics.volatile_load(&modus.thread_record().events)
		for _ in 0 ..< modus.RING_CAPACITY {
			rec, has := modus.ring_receive(&c.calls.completions)
			if !has {
				break
			}
			if rec.tag == tag {
				comp = rec
				answered = true
				break
			}
		}
		if answered {
			break
		}
		if !_storage_connected(c) {
			return 0, nil, .Permission_Denied
		}
		if modus.time_milliseconds() >= deadline {
			c.late_tag = tag
			return 0, nil, .Timeout
		}
		w := intrinsics.atomic_load_explicit(&c.calls.completions.counters.write, .Acquire)
		intrinsics.atomic_store_explicit(&c.calls.completions.counters.reader_waits, 1, .Release)
		modus.ring_complete(&c.calls.completions.counters.reader_waits)
		for _ in 0 ..< modus.RING_CAPACITY {
			rec, has := modus.ring_receive(&c.calls.completions)
			if !has {
				break
			}
			if rec.tag == tag {
				comp = rec
				answered = true
				break
			}
		}
		if answered {
			intrinsics.atomic_store_explicit(&c.calls.completions.counters.reader_waits, 0, .Release)
			break
		}
		words := [3]modus.Word{
			{address = u64(uintptr(&modus.thread_record().events)), value = u64(ev)},
			{address = u64(uintptr(&c.calls.completions.counters.write)), value = u64(w)},
			{address = u64(uintptr(&c.calls.completions.counters.reader_waits)), value = 1},
		}
		returned := modus.word_wait_many(words[:], deadline)
		intrinsics.atomic_store_explicit(&c.calls.completions.counters.reader_waits, 0, .Release)
		if returned >= deadline {
			for _ in 0 ..< modus.RING_CAPACITY {
				rec, has := modus.ring_receive(&c.calls.completions)
				if !has {
					break
				}
				if rec.tag == tag {
					comp = rec
					answered = true
					break
				}
			}
			if answered {
				break
			}
			c.late_tag = tag
			return 0, nil, .Timeout
		}
	}

	if comp.kind != 0 {
		outcome := modus.Call_Outcome.Answer_Unreadable
		if comp.kind <= u32(max(modus.Call_Outcome)) {
			outcome = modus.Call_Outcome(comp.kind)
		}
		return 0, nil, _modus_outcome_to_error(outcome)
	}

	answer := i64(comp.values[0])

	// Copy back Append/Change tables from the call region into caller buffers.
	for i in 0 ..< int(fn.parameter_count) {
		t := fn.parameters[i]
		dir := fn.parameter_directions[i]
		if (t == 5 || t == 6) && (dir == 1 || dir == 2) {
			elem_size: u64 = 1
			if t == 5 {
				rec, _ := _mod_record(c.file, _MOD_TABLE_RECORDS, fn.parameter_details[i], _Mod_Record)
				elem_size = u64(rec.size)
			}
			cap_recs := u64(len(args[i].table_bytes)) / elem_size
			if dir == 1 { // Change
				copied_recs := min(args[i].table_count, cap_recs)
				if copied_recs > 0 {
					intrinsics.mem_copy_non_overlapping(raw_data(args[i].table_bytes), raw_data(c.region[args[i].region_start:]), int(copied_recs * elem_size))
				}
			} else { // Append
				tf := _iso_load(c.region, args[i].field_offset, _Iso_Table_Field)
				first_record := min(args[i].table_count, cap_recs)
				kept_records := min(tf.count, cap_recs)
				if kept_records > first_record {
					intrinsics.mem_copy_non_overlapping(
						raw_data(args[i].table_bytes[first_record * elem_size:]),
						raw_data(c.region[args[i].region_start:]),
						int((kept_records - first_record) * elem_size),
					)
				}
				args[i].table_count = tf.count
			}
		}
	}

	if fn.result == 2 { // Text
		kept := min(u64(max(answer, 0)), res_slice.count)
		return answer, c.region[res_slice.start:][:kept], nil
	}
	if fn.result == 5 { // Table
		rec, _ := _mod_record(c.file, _MOD_TABLE_RECORDS, fn.result_detail, _Mod_Record)
		kept := min(u64(max(answer, 0)), res_slice.count)
		return answer, c.region[res_slice.start:][:kept * u64(rec.size)], nil
	}
	return answer, nil, nil
}

// Validates a relative path inside the private store: refuses leading '/',
// consecutive slashes '//', '..', NUL bytes, or components exceeding 255 bytes.
_storage_split_path :: proc(path: string, out: ^[_STORAGE_NESTING_LIMIT]string) -> (count: int, ok: bool) {
	if len(path) == 0 || path[0] == '/' {
		return 0, false
	}
	for i in 0 ..< len(path) {
		if path[i] == 0 {
			return 0, false
		}
	}
	i := 0
	for i < len(path) {
		if path[i] == '/' {
			return 0, false
		}
		start := i
		for i < len(path) && path[i] != '/' {
			i += 1
		}
		part := path[start:i]
		if i < len(path) && path[i] == '/' {
			i += 1
		}
		if part == "." {
			continue
		}
		if part == ".." || len(part) > _STORAGE_NAME_LIMIT {
			return 0, false
		}
		if count >= _STORAGE_NESTING_LIMIT {
			return 0, false
		}
		out[count] = part
		count += 1
	}
	return count, true
}

_storage_open_tree_locked :: proc(c: ^_Modus_Storage_Client, place: _Storage_Place, name: string) -> (_Storage_Place, Error) {
	args := [2]_Iso_Arg{{integer = u64(place)}, {text = transmute([]u8)name}}
	res, _, err := _storage_call_locked(c, "open", args[:])
	return _Storage_Place(res), err
}

_storage_close_tree_locked :: proc(c: ^_Modus_Storage_Client, place: _Storage_Place) {
	if place == _STORAGE_ROOT {
		return
	}
	args := [1]_Iso_Arg{{integer = u64(place)}}
	_, _, _ = _storage_call_locked(c, "close", args[:])
}

_storage_close_chain_locked :: proc(c: ^_Modus_Storage_Client, places: []_Storage_Place) {
	#reverse for p in places {
		_storage_close_tree_locked(c, p)
	}
}

_storage_walk_parent_locked :: proc(c: ^_Modus_Storage_Client, parts: []string, opened: ^[_STORAGE_NESTING_LIMIT]_Storage_Place) -> (parent: _Storage_Place, opened_count: int, err: Error) {
	parent = _STORAGE_ROOT
	for i in 0 ..< len(parts) - 1 {
		next_p: _Storage_Place
		next_p, err = _storage_open_tree_locked(c, parent, parts[i])
		if err != nil {
			_storage_close_chain_locked(c, opened[:opened_count])
			return _STORAGE_ROOT, 0, err
		}
		opened[opened_count] = next_p
		opened_count += 1
		parent = next_p
	}
	return parent, opened_count, nil
}

_storage_walk_dir_locked :: proc(c: ^_Modus_Storage_Client, parts: []string, opened: ^[_STORAGE_NESTING_LIMIT]_Storage_Place) -> (dir: _Storage_Place, opened_count: int, err: Error) {
	dir = _STORAGE_ROOT
	for i in 0 ..< len(parts) {
		next_p: _Storage_Place
		next_p, err = _storage_open_tree_locked(c, dir, parts[i])
		if err != nil {
			_storage_close_chain_locked(c, opened[:opened_count])
			return _STORAGE_ROOT, 0, err
		}
		opened[opened_count] = next_p
		opened_count += 1
		dir = next_p
	}
	return dir, opened_count, nil
}

_storage_size_locked :: proc(c: ^_Modus_Storage_Client, place: _Storage_Place, name: string) -> (i64, Error) {
	args := [2]_Iso_Arg{{integer = u64(place)}, {text = transmute([]u8)name}}
	sz, _, err := _storage_call_locked(c, "size", args[:])
	return sz, err
}

_storage_add_one_locked :: proc(c: ^_Modus_Storage_Client, place: _Storage_Place, name: string, kind: i64) -> Error {
	row := [1]_Storage_Add_Row{{name_offset = 0, name_count = i64(len(name)), kind = kind}}
	args := [3]_Iso_Arg{
		{integer = u64(place)},
		{table_bytes = ([^]u8)(&row[0])[:size_of(_Storage_Add_Row)], table_count = 1},
		{table_bytes = transmute([]u8)name, table_count = u64(len(name))},
	}
	_, _, err := _storage_call_locked(c, "add", args[:])
	return err
}

_storage_read_range_locked :: proc(c: ^_Modus_Storage_Client, place: _Storage_Place, name: string, offset: u64, dst: []u8) -> (int, Error) {
	args := [3]_Iso_Arg{{integer = u64(place)}, {text = transmute([]u8)name}, {integer = offset}}
	_, text, err := _storage_call_locked(c, "read_range", args[:])
	if err != nil {
		return 0, err
	}
	n := copy(dst, text)
	return n, nil
}

_storage_write_range_locked :: proc(c: ^_Modus_Storage_Client, place: _Storage_Place, name: string, offset: u64, src: []u8) -> (i64, Error) {
	args := [4]_Iso_Arg{{integer = u64(place)}, {text = transmute([]u8)name}, {integer = offset}, {text = src}}
	sz, _, err := _storage_call_locked(c, "write_range", args[:])
	return sz, err
}

_storage_set_size_locked :: proc(c: ^_Modus_Storage_Client, place: _Storage_Place, name: string, size: u64) -> Error {
	args := [3]_Iso_Arg{{integer = u64(place)}, {text = transmute([]u8)name}, {integer = size}}
	_, _, err := _storage_call_locked(c, "set_size", args[:])
	return err
}

_storage_commit_locked :: proc(c: ^_Modus_Storage_Client, place: _Storage_Place, name: string) -> Error {
	args := [2]_Iso_Arg{{integer = u64(place)}, {text = transmute([]u8)name}}
	_, _, err := _storage_call_locked(c, "commit", args[:])
	return err
}

_storage_remove_locked :: proc(c: ^_Modus_Storage_Client, place: _Storage_Place, name: string) -> Error {
	args := [2]_Iso_Arg{{integer = u64(place)}, {text = transmute([]u8)name}}
	_, _, err := _storage_call_locked(c, "remove", args[:])
	return err
}

_storage_rename_locked :: proc(c: ^_Modus_Storage_Client, place: _Storage_Place, name: string, to_place: _Storage_Place, to_name: string) -> Error {
	args := [4]_Iso_Arg{{integer = u64(place)}, {text = transmute([]u8)name}, {integer = u64(to_place)}, {text = transmute([]u8)to_name}}
	_, _, err := _storage_call_locked(c, "rename", args[:])
	return err
}

_storage_list_locked :: proc(c: ^_Modus_Storage_Client, place: _Storage_Place, after: string, rows: []_Storage_Listed, names: []u8) -> ([]_Storage_Listed, Error) {
	args := [4]_Iso_Arg{
		{integer = u64(place)},
		{text = transmute([]u8)after},
		{table_bytes = ([^]u8)(raw_data(rows))[:len(rows) * size_of(_Storage_Listed)], table_count = 0},
		{table_bytes = names, table_count = 0},
	}
	count, _, err := _storage_call_locked(c, "list", args[:])
	if err != nil {
		return nil, err
	}
	return rows[:clamp(int(count), 0, len(rows))], nil
}
