#+private
#+build modus
#+no-instrumentation
package runtime

import "base:intrinsics"

when !ODIN_TEST && !ODIN_NO_ENTRY_POINT {
	@(link_name="entry", linkage="strong", require, export)
	entry :: proc "c" (ctx: rawptr) -> ! {
		_ = ctx
		context = default_context()
		when !ODIN_BEDROCK {
			#force_no_inline _startup_runtime()
		}
		intrinsics.__entry_point()
		when !ODIN_BEDROCK {
			#force_no_inline _cleanup_runtime()
		}
		_modus_ready_at_end()
		_exit(0)
	}
}
