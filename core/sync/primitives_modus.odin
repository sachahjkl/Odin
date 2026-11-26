#+build modus
#+private
package sync

import "core:sys/modus"

_current_thread_id :: proc "contextless" () -> int {
	return int(modus.thread_record().number) + 1
}
