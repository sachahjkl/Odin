#+private
#+build modus
package os

import "base:runtime"
import "core:sys/modus"
import "core:time"

_get_uid :: proc() -> int {
	return 0
}

_get_euid :: proc() -> int {
	return 0
}

_get_gid :: proc() -> int {
	return 0
}

_get_egid :: proc() -> int {
	return 0
}

_get_pid :: proc() -> int {
	return 0
}

_get_ppid :: proc() -> int {
	return 0
}

_get_current_thread_id :: proc "contextless" () -> int {
	return int(modus.thread_record().number) + 1
}

_get_processor_core_count :: proc() -> int {
	return max(int(modus.thread_record().processors), 1)
}

_process_info_by_handle :: proc(process: Process, selection: Process_Info_Fields, allocator: runtime.Allocator) -> (info: Process_Info, err: Error) {
	return {}, .Unsupported
}

_current_process_info :: proc(selection: Process_Info_Fields, allocator: runtime.Allocator) -> (info: Process_Info, err: Error) {
	return {}, .Unsupported
}

_process_start :: proc(desc: Process_Desc) -> (process: Process, err: Error) {
	return {}, .Unsupported
}

_process_wait :: proc(process: Process, timeout: time.Duration) -> (process_state: Process_State, err: Error) {
	return {}, .Unsupported
}

_process_kill :: proc(process: Process) -> (err: Error) {
	return .Unsupported
}

_process_terminate :: proc(process: Process) -> (err: Error) {
	return .Unsupported
}

_process_info_by_pid :: proc(pid: int, selection: Process_Info_Fields, allocator: runtime.Allocator) -> (info: Process_Info, err: Error) {
	return {}, .Unsupported
}

_process_list :: proc(allocator: runtime.Allocator) -> (list: []int, err: Error) {
	return nil, .Unsupported
}

_process_open :: proc(pid: int, flags: Process_Open_Flags) -> (process: Process, err: Error) {
	process.pid = pid
	return process, .Unsupported
}

_process_handle_still_valid :: proc(p: Process) -> Error {
	return .Unsupported
}

_process_state_update_times :: proc(p: Process, state: ^Process_State) {
}
