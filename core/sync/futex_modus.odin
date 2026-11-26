#+private
#+build modus
package sync

import "base:intrinsics"
import "core:sys/modus"
import "core:time"

_futex_wait :: proc "contextless" (futex: ^Futex, expected: u32) -> bool {
	_ = modus.word_wait((^u32)(futex), expected, modus.WAIT_FOREVER)
	return true
}

_futex_wait_with_timeout :: proc "contextless" (futex: ^Futex, expected: u32, duration: time.Duration) -> bool {
	if duration <= 0 {
		return false
	}
	ms := (u64(duration) + 999_999) / 1_000_000
	if ms == 0 {
		ms = 1
	}
	now := modus.time_milliseconds()
	deadline := modus.WAIT_FOREVER if now > modus.WAIT_FOREVER - ms else now + ms
	returned := modus.word_wait((^u32)(futex), expected, max(deadline, 1))
	if returned >= deadline && intrinsics.atomic_load((^u32)(futex)) == expected {
		return false
	}
	return true
}

_futex_signal :: proc "contextless" (futex: ^Futex) {
	_ = modus.word_wake((^u32)(futex), 1)
}

_futex_broadcast :: proc "contextless" (futex: ^Futex) {
	_ = modus.word_wake((^u32)(futex), max(u64))
}
