#+private
#+build modus
package os

import "base:runtime"
import "core:io"
import "core:sync"
import "core:sys/modus"
import "core:time"

_File_Kind :: enum u8 {
	Stdin,
	Stdout,
	Stderr,
	Storage_Object,
	Storage_Dir,
}

File_Impl :: struct {
	file:      File,
	name:      string,
	leaf:      string,
	place:     _Storage_Place,
	kind:      _File_Kind,
	flags:     File_Flags,
	offset:    i64,
	dirty:     bool,
	allocator: runtime.Allocator,
}

@(private="file")
_Log_Buffer :: struct {
	lock:  modus.Lock,
	level: modus.Log_Level,
	len:   int,
	buf:   [modus.LOG_TEXT_BYTES_MOST]u8,
}

@(private="file")
_stdout_log: _Log_Buffer
@(private="file")
_stderr_log: _Log_Buffer

@(private="file")
_log_buffer_flush_locked :: proc "contextless" (lb: ^_Log_Buffer, allow_empty: bool = false) {
	if lb.len > 0 || allow_empty {
		_ = modus.log_write(lb.level, lb.buf[:lb.len])
		lb.len = 0
	}
}

@(private="file")
_log_buffer_write :: proc "contextless" (lb: ^_Log_Buffer, data: []byte) -> i64 {
	modus.lock(&lb.lock)
	defer modus.unlock(&lb.lock)
	for b in data {
		if b == '\n' {
			_log_buffer_flush_locked(lb, allow_empty = true)
			continue
		}
		if lb.len >= len(lb.buf) {
			_log_buffer_flush_locked(lb)
		}
		lb.buf[lb.len] = b
		lb.len += 1
	}
	return i64(len(data))
}

@(private="file")
_log_buffer_flush :: proc "contextless" (lb: ^_Log_Buffer) {
	modus.lock(&lb.lock)
	_log_buffer_flush_locked(lb)
	modus.unlock(&lb.lock)
}

@(init)
init_std_files :: proc "contextless" () {
	new_std :: proc "contextless" (impl: ^File_Impl, kind: _File_Kind, name: string) -> ^File {
		impl.file.impl = impl
		impl.allocator = runtime.nil_allocator()
		impl.kind = kind
		impl.name = name
		impl.file.stream = {
			data      = impl,
			procedure = _file_stream_proc,
		}
		return &impl.file
	}

	_stdout_log.level = .Info
	_stderr_log.level = .Error

	@(static) files: [3]File_Impl
	stdin  = new_std(&files[0], .Stdin,  "stdin")
	stdout = new_std(&files[1], .Stdout, "stdout")
	stderr = new_std(&files[2], .Stderr, "stderr")
}

@(fini)
fini_std_files :: proc "contextless" () {
	_log_buffer_flush(&_stdout_log)
	_log_buffer_flush(&_stderr_log)
}

@(private="file")
_file_can_read :: #force_inline proc "contextless" (flags: File_Flags) -> bool {
	return .Read in flags || (.Write not_in flags)
}

@(private="file")
_file_can_write :: #force_inline proc "contextless" (flags: File_Flags) -> bool {
	return .Write in flags
}

_open :: proc(name: string, flags: File_Flags, perm: Permissions) -> (f: ^File, err: Error) {
	_ = perm
	parts: [_STORAGE_NESTING_LIMIT]string
	count, path_ok := _storage_split_path(name, &parts)
	if !path_ok {
		return nil, .Invalid_Path
	}

	sync.guard(&g_storage_mutex)
	c := _storage_ensure_open_locked() or_return

	kind := _File_Kind.Storage_Object
	initial_offset: i64 = 0
	kept_place := _STORAGE_ROOT
	leaf_name := ""

	opened: [_STORAGE_NESTING_LIMIT]_Storage_Place
	opened_n := 0
	keep_parent := false
	defer {
		if err != nil {
			if !keep_parent && kept_place != _STORAGE_ROOT {
				_storage_close_tree_locked(c, kept_place)
			}
			_storage_close_chain_locked(c, opened[:opened_n])
		} else if keep_parent && opened_n > 0 {
			// Transfer ownership of opened[opened_n - 1] (the parent tree) to File_Impl.
			_storage_close_chain_locked(c, opened[:opened_n - 1])
		} else {
			_storage_close_chain_locked(c, opened[:opened_n])
		}
	}

	if count == 0 {
		if .Write in flags || .Create in flags || .Trunc in flags {
			return nil, .Invalid_File
		}
		kind = .Storage_Dir
		kept_place = _STORAGE_ROOT
	} else {
		parent: _Storage_Place
		parent, opened_n = _storage_walk_parent_locked(c, parts[:count], &opened) or_return
		leaf := parts[count - 1]

		sz, sz_err := _storage_size_locked(c, parent, leaf)
		if sz_err == nil {
			if .Create in flags && .Excl in flags {
				return nil, .Exist
			}
			if .Trunc in flags && .Write in flags {
				_storage_set_size_locked(c, parent, leaf, 0) or_return
				_storage_commit_locked(c, parent, leaf) or_return
				sz = 0
			}
			if .Append in flags {
				initial_offset = sz
			}
			kind = .Storage_Object
			kept_place = parent
			keep_parent = true
			leaf_name = leaf
		} else {
			// Storage `size` returns Nothing_Has_That_Name (.Not_Exist) for trees too,
			// so probe `open` before concluding the entry does not exist.
			if dir_p, dir_err := _storage_open_tree_locked(c, parent, leaf); dir_err == nil {
				if .Write in flags || .Create in flags || .Trunc in flags {
					_storage_close_tree_locked(c, dir_p)
					return nil, .Invalid_File
				}
				kind = .Storage_Dir
				kept_place = dir_p
			} else if sz_err == .Not_Exist {
				if .Create in flags {
					_storage_add_one_locked(c, parent, leaf, _STORAGE_ENTRY_OBJECT) or_return
					kind = .Storage_Object
					kept_place = parent
					keep_parent = true
					leaf_name = leaf
				} else {
					return nil, .Not_Exist
				}
			} else {
				return nil, sz_err
			}
		}
	}

	impl := new(File_Impl, file_allocator()) or_return
	defer if err != nil {
		delete(impl.leaf, impl.allocator)
		delete(impl.name, impl.allocator)
		free(impl, file_allocator())
	}
	impl.allocator = file_allocator()
	impl.name = clone_string(name, impl.allocator) or_return
	if len(leaf_name) > 0 {
		impl.leaf = clone_string(leaf_name, impl.allocator) or_return
	}
	impl.place = kept_place
	impl.kind = kind
	impl.flags = flags
	impl.offset = initial_offset
	impl.file.impl = impl
	impl.file.stream = {
		data      = impl,
		procedure = _file_stream_proc,
	}
	return &impl.file, nil
}

_new_file :: proc(handle: uintptr, name: string, allocator: runtime.Allocator) -> (f: ^File, err: Error) {
	_ = handle
	_ = name
	_ = allocator
	return nil, .Unsupported
}

_clone :: proc(f: ^File) -> (clone: ^File, err: Error) {
	if f == nil || f.impl == nil {
		return nil, .Invalid_File
	}
	impl := (^File_Impl)(f.impl)
	switch impl.kind {
	case .Stdin:  return stdin, nil
	case .Stdout: return stdout, nil
	case .Stderr: return stderr, nil
	case .Storage_Object, .Storage_Dir:
		return _open(impl.name, impl.flags - {.Create, .Excl, .Trunc}, Permissions_Default_File)
	}
	return nil, .Unsupported
}

_close :: proc(f: ^File_Impl) -> (err: Error) {
	if f == nil {
		return nil
	}
	switch f.kind {
	case .Stdin:
		return nil
	case .Stdout:
		_log_buffer_flush(&_stdout_log)
		return nil
	case .Stderr:
		_log_buffer_flush(&_stderr_log)
		return nil
	case .Storage_Object:
		if f.dirty {
			err = _sync(&f.file)
		}
		if f.place != _STORAGE_ROOT {
			sync.guard(&g_storage_mutex)
			if c, open_err := _storage_ensure_open_locked(); open_err == nil {
				_storage_close_tree_locked(c, f.place)
			}
			f.place = _STORAGE_ROOT
		}
	case .Storage_Dir:
		if f.place != _STORAGE_ROOT {
			sync.guard(&g_storage_mutex)
			if c, open_err := _storage_ensure_open_locked(); open_err == nil {
				_storage_close_tree_locked(c, f.place)
			}
			f.place = _STORAGE_ROOT
		}
	}
	delete(f.leaf, f.allocator)
	delete(f.name, f.allocator)
	free(f, f.allocator)
	return err
}

_fd :: proc(f: ^File) -> uintptr {
	if f == nil || f.impl == nil {
		return ~uintptr(0)
	}
	impl := (^File_Impl)(f.impl)
	switch impl.kind {
	case .Stdin:  return 0
	case .Stdout: return 1
	case .Stderr: return 2
	case .Storage_Object, .Storage_Dir:
		return uintptr(impl)
	}
	return ~uintptr(0)
}

_is_tty :: proc "contextless" (f: ^File) -> bool {
	_ = f
	return false
}

_name :: proc(f: ^File) -> string {
	if f != nil && f.impl != nil {
		return (^File_Impl)(f.impl).name
	}
	return ""
}

_sync :: proc(f: ^File) -> Error {
	if f == nil || f.impl == nil {
		return .Invalid_File
	}
	impl := (^File_Impl)(f.impl)
	switch impl.kind {
	case .Stdin:
		return nil
	case .Stdout:
		_log_buffer_flush(&_stdout_log)
		return nil
	case .Stderr:
		_log_buffer_flush(&_stderr_log)
		return nil
	case .Storage_Dir:
		return nil
	case .Storage_Object:
		if !impl.dirty {
			return nil
		}
		sync.guard(&g_storage_mutex)
		c := _storage_ensure_open_locked() or_return
		_storage_commit_locked(c, impl.place, impl.leaf) or_return
		impl.dirty = false
		return nil
	}
	return .Unsupported
}

_truncate :: proc(f: ^File, size: i64) -> Error {
	if f == nil || f.impl == nil || size < 0 {
		return .Invalid_File
	}
	impl := (^File_Impl)(f.impl)
	if impl.kind != .Storage_Object {
		return .Unsupported
	}
	if !_file_can_write(impl.flags) {
		return .Permission_Denied
	}
	sync.guard(&g_storage_mutex)
	c := _storage_ensure_open_locked() or_return
	_storage_set_size_locked(c, impl.place, impl.leaf, u64(size)) or_return
	_storage_commit_locked(c, impl.place, impl.leaf) or_return
	impl.dirty = false
	return nil
}

_remove :: proc(name: string) -> Error {
	parts: [_STORAGE_NESTING_LIMIT]string
	count, ok := _storage_split_path(name, &parts)
	if !ok || count == 0 {
		return .Invalid_Path
	}
	sync.guard(&g_storage_mutex)
	c := _storage_ensure_open_locked() or_return
	opened: [_STORAGE_NESTING_LIMIT]_Storage_Place
	parent, opened_n := _storage_walk_parent_locked(c, parts[:count], &opened) or_return
	defer _storage_close_chain_locked(c, opened[:opened_n])
	return _storage_remove_locked(c, parent, parts[count - 1])
}

_rename :: proc(old_path, new_path: string) -> Error {
	old_parts: [_STORAGE_NESTING_LIMIT]string
	old_count, old_ok := _storage_split_path(old_path, &old_parts)
	if !old_ok || old_count == 0 {
		return .Invalid_Path
	}
	new_parts: [_STORAGE_NESTING_LIMIT]string
	new_count, new_ok := _storage_split_path(new_path, &new_parts)
	if !new_ok || new_count == 0 {
		return .Invalid_Path
	}

	sync.guard(&g_storage_mutex)
	c := _storage_ensure_open_locked() or_return

	old_opened: [_STORAGE_NESTING_LIMIT]_Storage_Place
	old_parent, old_n := _storage_walk_parent_locked(c, old_parts[:old_count], &old_opened) or_return
	defer _storage_close_chain_locked(c, old_opened[:old_n])

	new_opened: [_STORAGE_NESTING_LIMIT]_Storage_Place
	new_parent, new_n := _storage_walk_parent_locked(c, new_parts[:new_count], &new_opened) or_return
	defer _storage_close_chain_locked(c, new_opened[:new_n])

	return _storage_rename_locked(c, old_parent, old_parts[old_count - 1], new_parent, new_parts[new_count - 1])
}

_link :: proc(old_name, new_name: string) -> Error {
	return .Unsupported
}

_symlink :: proc(old_name, new_name: string) -> Error {
	return .Unsupported
}

_read_link :: proc(name: string, allocator: runtime.Allocator) -> (s: string, err: Error) {
	return "", .Unsupported
}

_chdir :: proc(name: string) -> Error {
	return .Unsupported
}

_fchdir :: proc(f: ^File) -> Error {
	return .Unsupported
}

_fchmod :: proc(f: ^File, mode: Permissions) -> Error {
	return .Unsupported
}

_chmod :: proc(name: string, mode: Permissions) -> Error {
	return .Unsupported
}

_fchown :: proc(f: ^File, uid, gid: int) -> Error {
	return .Unsupported
}

_chown :: proc(name: string, uid, gid: int) -> Error {
	return .Unsupported
}

_lchown :: proc(name: string, uid, gid: int) -> Error {
	return .Unsupported
}

_chtimes :: proc(name: string, atime, mtime: time.Time) -> Error {
	return .Unsupported
}

_fchtimes :: proc(f: ^File, atime, mtime: time.Time) -> Error {
	return .Unsupported
}

_exists :: proc(path: string) -> bool {
	parts: [_STORAGE_NESTING_LIMIT]string
	count, ok := _storage_split_path(path, &parts)
	if !ok {
		return false
	}
	sync.guard(&g_storage_mutex)
	c, err := _storage_ensure_open_locked()
	if err != nil {
		return false
	}
	if count == 0 {
		return true
	}
	opened: [_STORAGE_NESTING_LIMIT]_Storage_Place
	parent, opened_n, walk_err := _storage_walk_parent_locked(c, parts[:count], &opened)
	if walk_err != nil {
		return false
	}
	defer _storage_close_chain_locked(c, opened[:opened_n])
	leaf := parts[count - 1]
	if _, sz_err := _storage_size_locked(c, parent, leaf); sz_err == nil {
		return true
	}
	if dir_p, dir_err := _storage_open_tree_locked(c, parent, leaf); dir_err == nil {
		_storage_close_tree_locked(c, dir_p)
		return true
	}
	return false
}

@(private="file")
_storage_file_read_at :: proc(impl: ^File_Impl, p: []byte, offset: i64) -> (n: i64, err: Error) {
	if !_file_can_read(impl.flags) {
		return 0, .Permission_Denied
	}
	if offset < 0 {
		return 0, .Invalid_Offset
	}
	if len(p) == 0 {
		return 0, nil
	}

	sync.guard(&g_storage_mutex)
	c := _storage_ensure_open_locked() or_return

	sz := _storage_size_locked(c, impl.place, impl.leaf) or_return
	if offset >= sz {
		return 0, .EOF
	}

	for n < i64(len(p)) && offset + n < sz {
		chunk_read: int
		chunk_read, err = _storage_read_range_locked(c, impl.place, impl.leaf, u64(offset + n), p[n:])
		if err != nil {
			return n, err
		}
		if chunk_read == 0 {
			break
		}
		n += i64(chunk_read)
	}
	if n < i64(len(p)) {
		return n, .EOF
	}
	return n, nil
}

@(private="file")
_storage_file_write_at :: proc(impl: ^File_Impl, p: []byte, offset: i64) -> (n: i64, err: Error) {
	if !_file_can_write(impl.flags) {
		return 0, .Permission_Denied
	}
	if offset < 0 {
		return 0, .Invalid_Offset
	}
	if len(p) == 0 {
		return 0, nil
	}

	sync.guard(&g_storage_mutex)
	c := _storage_ensure_open_locked() or_return

	// Leave headroom in the call region for the argument record and entry name.
	REGION_HEADROOM :: 1024
	if len(c.region) <= REGION_HEADROOM {
		return 0, .Out_Of_Memory
	}
	max_chunk := len(c.region) - REGION_HEADROOM
	pos := offset
	rem := p
	for len(rem) > 0 {
		chunk := min(len(rem), max_chunk)
		_, err = _storage_write_range_locked(c, impl.place, impl.leaf, u64(pos), rem[:chunk])
		if err != nil {
			return n, err
		}
		impl.dirty = true
		rem = rem[chunk:]
		pos += i64(chunk)
		n += i64(chunk)
	}
	if .Sync in impl.flags {
		_storage_commit_locked(c, impl.place, impl.leaf) or_return
		impl.dirty = false
	}
	return n, nil
}

@(private="file")
_storage_file_size :: proc(impl: ^File_Impl) -> (size: i64, err: Error) {
	sync.guard(&g_storage_mutex)
	c := _storage_ensure_open_locked() or_return
	return _storage_size_locked(c, impl.place, impl.leaf)
}

_file_stream_proc :: proc(stream_data: rawptr, mode: File_Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From, allocator: runtime.Allocator) -> (n: i64, err: Error) {
	f := (^File_Impl)(stream_data)
	if f == nil {
		return 0, .Invalid_File
	}

	switch f.kind {
	case .Stdin:
		switch mode {
		case .Read, .Read_At:
			return 0, .EOF
		case .Close, .Destroy, .Flush:
			return 0, nil
		case .Query:
			return io.query_utility({.Read, .Close, .Destroy, .Query})
		case .Fstat:
			err = file_stream_fstat_utility(f, p, allocator)
			return
		case .Write, .Write_At, .Seek, .Size:
			return 0, .Unsupported
		}

	case .Stdout, .Stderr:
		lb := &_stdout_log if f.kind == .Stdout else &_stderr_log
		switch mode {
		case .Write:
			return _log_buffer_write(lb, p), nil
		case .Flush, .Close, .Destroy:
			_log_buffer_flush(lb)
			return 0, nil
		case .Query:
			return io.query_utility({.Write, .Flush, .Close, .Destroy, .Query})
		case .Fstat:
			err = file_stream_fstat_utility(f, p, allocator)
			return
		case .Read, .Read_At, .Write_At, .Seek, .Size:
			return 0, .Unsupported
		}

	case .Storage_Dir:
		switch mode {
		case .Close, .Destroy:
			return 0, _close(f)
		case .Flush:
			return 0, nil
		case .Query:
			return io.query_utility({.Close, .Destroy, .Query})
		case .Fstat:
			err = file_stream_fstat_utility(f, p, allocator)
			return
		case .Read, .Read_At, .Write, .Write_At, .Seek, .Size:
			return 0, .Unsupported
		}

	case .Storage_Object:
		switch mode {
		case .Read:
			n, err = _storage_file_read_at(f, p, f.offset)
			f.offset += n
			if err == .EOF && n > 0 {
				err = nil
			}
			return
		case .Read_At:
			return _storage_file_read_at(f, p, offset)
		case .Write:
			if !_file_can_write(f.flags) {
				return 0, .Permission_Denied
			}
			if .Append in f.flags {
				sz, sz_err := _storage_file_size(f)
				if sz_err != nil {
					return 0, sz_err
				}
				f.offset = sz
			}
			n, err = _storage_file_write_at(f, p, f.offset)
			f.offset += n
			return
		case .Write_At:
			return _storage_file_write_at(f, p, offset)
		case .Seek:
			target: i64
			switch whence {
			case .Start:
				target = offset
			case .Current:
				target = f.offset + offset
			case .End:
				sz := _storage_file_size(f) or_return
				target = sz + offset
			case:
				return 0, .Invalid_Whence
			}
			if target < 0 {
				return 0, .Invalid_Offset
			}
			f.offset = target
			return target, nil
		case .Size:
			return _storage_file_size(f)
		case .Flush:
			return 0, _sync(&f.file)
		case .Close, .Destroy:
			return 0, _close(f)
		case .Query:
			modes: io.Stream_Mode_Set = {.Seek, .Size, .Flush, .Close, .Destroy, .Query}
			if _file_can_read(f.flags) {
				modes += {.Read, .Read_At}
			}
			if _file_can_write(f.flags) {
				modes += {.Write, .Write_At}
			}
			return io.query_utility(modes)
		case .Fstat:
			err = file_stream_fstat_utility(f, p, allocator)
			return
		}
	}

	return 0, .Unsupported
}
