#+private
#+build modus
package os

_pipe :: proc() -> (r, w: ^File, err: Error) {
	return nil, nil, .Unsupported
}

@(require_results)
_pipe_has_data :: proc(r: ^File) -> (ok: bool, err: Error) {
	_ = r
	return false, .Unsupported
}
