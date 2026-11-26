#+private
#+build modus
package os

import "base:runtime"
import "core:sync"

_Path_Separator        :: '/'
_Path_Separator_String :: "/"
_Path_List_Separator   :: ':'

_is_path_separator :: proc(c: byte) -> bool {
	return c == _Path_Separator
}

_mkdir :: proc(name: string, perm: Permissions) -> Error {
	_ = perm
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
	return _storage_add_one_locked(c, parent, parts[count - 1], _STORAGE_ENTRY_TREE)
}

_mkdir_all :: proc(path: string, perm: Permissions) -> Error {
	_ = perm
	parts: [_STORAGE_NESTING_LIMIT]string
	count, ok := _storage_split_path(path, &parts)
	if !ok || count == 0 {
		return .Invalid_Path
	}

	sync.guard(&g_storage_mutex)
	c := _storage_ensure_open_locked() or_return

	opened: [_STORAGE_NESTING_LIMIT]_Storage_Place
	opened_n := 0
	defer _storage_close_chain_locked(c, opened[:opened_n])

	cur := _STORAGE_ROOT
	for i in 0 ..< count {
		next_p, open_err := _storage_open_tree_locked(c, cur, parts[i])
		if open_err == .Not_Exist {
			_storage_add_one_locked(c, cur, parts[i], _STORAGE_ENTRY_TREE) or_return
			if i + 1 < count {
				next_p = _storage_open_tree_locked(c, cur, parts[i]) or_return
			} else {
				return nil
			}
		} else if open_err != nil {
			return open_err
		}
		if i + 1 < count {
			opened[opened_n] = next_p
			opened_n += 1
			cur = next_p
		} else {
			_storage_close_tree_locked(c, next_p)
		}
	}
	return nil
}

_remove_all :: proc(path: string) -> Error {
	// Modus storage `remove` removes an object or an entire subtree atomically.
	return _remove(path)
}

_get_working_directory :: proc(allocator: runtime.Allocator) -> (dir: string, err: Error) {
	return clone_string(".", allocator)
}

_set_working_directory :: proc(dir: string) -> (err: Error) {
	_ = dir
	return .Unsupported
}

_get_executable_path :: proc(allocator: runtime.Allocator) -> (path: string, err: Error) {
	_ = allocator
	return "", .Unsupported
}

_get_absolute_path :: proc(path: string, allocator: runtime.Allocator) -> (absolute_path: string, err: Error) {
	_ = path
	_ = allocator
	return "", .Unsupported
}
