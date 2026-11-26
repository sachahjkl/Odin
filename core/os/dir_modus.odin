#+private
#+build modus
package os

import "core:sync"

Read_Directory_Iterator_Impl :: struct {
	entries:  [dynamic]File_Info,
	fullpath: [dynamic]byte,
	pos:      int,
}

@(require_results)
_read_directory_iterator :: proc(it: ^Read_Directory_Iterator) -> (fi: File_Info, index: int, ok: bool) {
	if it.impl.pos >= len(it.impl.entries) {
		return {}, 0, false
	}
	fi = it.impl.entries[it.impl.pos]
	it.impl.pos += 1
	index = it.index
	it.index += 1
	return fi, index, true
}

_read_directory_iterator_init :: proc(it: ^Read_Directory_Iterator, f: ^File) {
	for e in it.impl.entries {
		file_info_delete(e, file_allocator())
	}
	clear(&it.impl.entries)
	it.impl.entries.allocator = file_allocator()
	it.impl.pos = 0

	if f == nil || f.impl == nil {
		read_directory_iterator_set_error(it, "", .Invalid_File)
		return
	}
	impl := (^File_Impl)(f.impl)
	if impl.kind != .Storage_Dir {
		read_directory_iterator_set_error(it, impl.name, .Invalid_Dir)
		return
	}

	sync.guard(&g_storage_mutex)
	c, open_err := _storage_ensure_open_locked()
	if open_err != nil {
		read_directory_iterator_set_error(it, impl.name, open_err)
		return
	}

	dir_place := impl.place
	is_root := dir_place == _STORAGE_ROOT

	rows_buf: [64]_Storage_Listed
	names_buf: [4096]u8
	after_buf: [_STORAGE_NAME_LIMIT]u8
	after_len := 0

	for {
		page, list_err := _storage_list_locked(c, dir_place, string(after_buf[:after_len]), rows_buf[:], names_buf[:])
		if list_err != nil {
			read_directory_iterator_set_error(it, impl.name, list_err)
			return
		}
		if len(page) == 0 {
			break
		}
		for row in page {
			if row.name_offset < 0 || row.name_count <= 0 || int(row.name_offset + row.name_count) > len(names_buf) {
				continue
			}
			entry_name := string(names_buf[row.name_offset:][:row.name_count])
			full: string
			alloc_err: Error
			if is_root {
				full, alloc_err = clone_string(entry_name, file_allocator())
			} else if len(impl.name) > 0 && impl.name[len(impl.name) - 1] == '/' {
				full, alloc_err = concatenate({impl.name, entry_name}, file_allocator())
			} else {
				full, alloc_err = concatenate({impl.name, "/", entry_name}, file_allocator())
			}
			if alloc_err != nil {
				read_directory_iterator_set_error(it, entry_name, alloc_err)
				return
			}
			fi: File_Info
			fi.fullpath = full
			_, fi.name = split_path(fi.fullpath)
			fi.size = row.size
			switch row.kind {
			case _STORAGE_ENTRY_OBJECT:
				fi.type = .Regular
				fi.mode = Permissions_Default_File
			case _STORAGE_ENTRY_TREE:
				fi.type = .Directory
				fi.mode = Permissions_Default_Directory
			case:
				fi.type = .Undetermined
			}
			if _, append_err := append(&it.impl.entries, fi); append_err != nil {
				file_info_delete(fi, file_allocator())
				read_directory_iterator_set_error(it, entry_name, append_err)
				return
			}
			after_len = copy(after_buf[:], entry_name)
		}
	}
}

_read_directory_iterator_destroy :: proc(it: ^Read_Directory_Iterator) {
	for e in it.impl.entries {
		file_info_delete(e, file_allocator())
	}
	delete(it.impl.entries)
	delete(it.impl.fullpath)
}
