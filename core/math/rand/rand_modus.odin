#+build modus
#+private
package rand

import "core:sys/modus"

_MODUS_THREAD_CAPACITY :: modus.THREAD_CAPACITY

_modus_thread_slot :: #force_inline proc "contextless" () -> u32 {
	return u32(modus.thread_record().number) & (modus.THREAD_CAPACITY - 1)
}
