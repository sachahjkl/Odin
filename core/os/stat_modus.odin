#+private
#+build modus
package os

import "base:runtime"
import "core:sync"

_fstat :: proc(f: ^File, allocator: runtime.Allocator) -> (fi: File_Info, err: Error) {
	if f == nil || f.impl == nil {
		return {}, .Invalid_File
	}
	impl := (^File_Impl)(f.impl)
	switch impl.kind {
	case .Stdin, .Stdout, .Stderr:
		fi.fullpath = clone_string(impl.name, allocator) or_return
		fi.name = fi.fullpath
		fi.type = .Character_Device
		return fi, nil
	case .Storage_Object:
		sync.guard(&g_storage_mutex)
		c := _storage_ensure_open_locked() or_return
		sz := _storage_size_locked(c, impl.place, impl.leaf) or_return
		fi.fullpath = clone_string(impl.name, allocator) or_return
		_, fi.name = split_path(fi.fullpath)
		fi.size = sz
		fi.type = .Regular
		fi.mode = Permissions_Default_File
		return fi, nil
	case .Storage_Dir:
		sync.guard(&g_storage_mutex)
		_ = _storage_ensure_open_locked() or_return
		fi.fullpath = clone_string(impl.name, allocator) or_return
		_, fi.name = split_path(fi.fullpath)
		fi.type = .Directory
		fi.mode = Permissions_Default_Directory
		return fi, nil
	}
	return {}, .Unsupported
}

_stat :: proc(name: string, allocator: runtime.Allocator) -> (fi: File_Info, err: Error) {
	parts: [_STORAGE_NESTING_LIMIT]string
	count, ok := _storage_split_path(name, &parts)
	if !ok {
		return {}, .Invalid_Path
	}

	sync.guard(&g_storage_mutex)
	c := _storage_ensure_open_locked() or_return

	if count == 0 {
		fi.fullpath = clone_string(".", allocator) or_return
		fi.name = fi.fullpath
		fi.type = .Directory
		fi.mode = Permissions_Default_Directory
		return fi, nil
	}

	opened: [_STORAGE_NESTING_LIMIT]_Storage_Place
	parent, opened_n := _storage_walk_parent_locked(c, parts[:count], &opened) or_return
	defer _storage_close_chain_locked(c, opened[:opened_n])

	leaf := parts[count - 1]
	sz, sz_err := _storage_size_locked(c, parent, leaf)
	if sz_err == nil {
		fi.fullpath = clone_string(name, allocator) or_return
		_, fi.name = split_path(fi.fullpath)
		fi.size = sz
		fi.type = .Regular
		fi.mode = Permissions_Default_File
		return fi, nil
	}
	// Storage `size` returns Nothing_Has_That_Name (.Not_Exist) when the entry is a tree,
	// so always probe `open` before returning .Not_Exist.
	if dir_p, dir_err := _storage_open_tree_locked(c, parent, leaf); dir_err == nil {
		_storage_close_tree_locked(c, dir_p)
		fi.fullpath = clone_string(name, allocator) or_return
		_, fi.name = split_path(fi.fullpath)
		fi.type = .Directory
		fi.mode = Permissions_Default_Directory
		return fi, nil
	}
	return {}, sz_err
}

_lstat :: proc(name: string, allocator: runtime.Allocator) -> (fi: File_Info, err: Error) {
	return _stat(name, allocator)
}

_same_file :: proc(fi1, fi2: File_Info) -> bool {
	return fi1.fullpath == fi2.fullpath
}

_is_reserved_name :: proc(path: string) -> bool {
	_ = path
	return false
}
