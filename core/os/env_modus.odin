#+private
#+build modus
package os

import "base:runtime"

// Modus processes have zero ambient environment variables.

@(require_results)
_lookup_env_alloc :: proc(key: string, allocator: runtime.Allocator) -> (value: string, found: bool) {
	_ = key
	_ = allocator
	return "", false
}

_lookup_env_buf :: proc(buf: []u8, key: string) -> (value: string, error: Error) {
	_ = buf
	if key == "" {
		return "", nil
	}
	return "", .Env_Var_Not_Found
}
_lookup_env :: proc{_lookup_env_alloc, _lookup_env_buf}

@(require_results)
_set_env :: proc(key, value: string) -> (err: Error) {
	_ = key
	_ = value
	return .Unsupported
}

@(require_results)
_unset_env :: proc(key: string) -> bool {
	_ = key
	return false
}

_clear_env :: proc() {
}

@(require_results)
_environ :: proc(allocator: runtime.Allocator) -> (environ: []string, err: Error) {
	_ = allocator
	return nil, nil
}
