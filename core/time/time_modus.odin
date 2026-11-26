#+private
#+build modus
package time

import "base:intrinsics"
import "core:sys/modus"

_IS_SUPPORTED :: true

_tick_now :: proc "contextless" () -> Tick {
	return Tick{_nsec = i64(modus.nanoseconds())}
}

_get_tsc_frequency :: proc "contextless" () -> (u64, bool) {
	record := (^modus.Time_Record)(uintptr(modus.TIME_ADDRESS))
	freq := record.cycle_frequency
	if freq == 0 {
		return 0, false
	}
	return freq, true
}

_now :: proc "contextless" () -> Time {
	ctx := modus.context_record()
	if .Date_Page in modus.ranges_mapped(&ctx.values) {
		page := (^modus.Date_Page)(uintptr(modus.DATE_PAGE_ADDRESS))
		for _ in 0 ..< modus.DATE_READ_TRIES {
			before := intrinsics.atomic_load_explicit(&page.change_count, .Acquire)
			if before & 1 != 0 {
				intrinsics.cpu_relax()
				continue
			}
			source := intrinsics.atomic_load_explicit(&page.source, .Acquire)
			at_zero_ms := intrinsics.atomic_load_explicit(&page.milliseconds_at_time_zero, .Acquire)
			if intrinsics.atomic_load_explicit(&page.change_count, .Acquire) != before {
				continue
			}
			if source == 1 && at_zero_ms > 0 && at_zero_ms < modus.DATE_MILLISECONDS_LIMIT {
				max_ns :: u64(max(i64))
				if u64(at_zero_ms) <= max_ns / 1_000_000 {
					base_ns := u64(at_zero_ms) * 1_000_000
					mono_ns := modus.nanoseconds()
					if mono_ns <= max_ns - base_ns {
						return Time{_nsec = i64(base_ns + mono_ns)}
					}
				}
			}
			break
		}
	}
	return Time{_nsec = _tick_now()._nsec}
}

_sleep :: proc "contextless" (d: Duration) {
	if d <= 0 {
		return
	}
	ms := (u64(d) + 999_999) / 1_000_000
	if ms == 0 {
		ms = 1
	}
	now := modus.time_milliseconds()
	deadline := modus.WAIT_FOREVER if now > modus.WAIT_FOREVER - ms else now + ms
	target := max(deadline, 1)
	for {
		returned := modus.system_enter(target)
		if returned >= target {
			return
		}
	}
}

_yield :: proc "contextless" () {
	_ = modus.system_enter(0)
}
