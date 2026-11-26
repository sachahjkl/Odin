#+build modus
#+private
package runtime

import "base:intrinsics"

_HAS_RAND_BYTES :: true

@(private="file")
_modus_rand_lock: _Modus_Lock
@(private="file")
_modus_rand_buf: [1024]byte
@(private="file")
_modus_rand_off: int
@(private="file")
_modus_rand_seeded: bool

@(private="file")
_modus_rotl32 :: #force_inline proc "contextless" (x: u32, k: uint) -> u32 {
	return (x << k) | (x >> (32 - k))
}

@(private="file")
_modus_chacha8_refill :: proc "contextless" () {
	k := ([^]u32)(raw_data(_modus_rand_buf[RNG_OUTPUT_PER_ITER:]))
	s4  := k[0]
	s5  := k[1]
	s6  := k[2]
	s7  := k[3]
	s8  := k[4]
	s9  := k[5]
	s10 := k[6]
	s11 := k[7]
	s12: u32
	s13, s14, s15: u32

	dst := ([^]u32)(raw_data(_modus_rand_buf[:]))

	qr :: #force_inline proc "contextless" (a, b, c, d: u32) -> (u32, u32, u32, u32) {
		a, b, c, d := a, b, c, d
		a += b; d ~= a; d = _modus_rotl32(d, 16)
		c += d; b ~= c; b = _modus_rotl32(b, 12)
		a += b; d ~= a; d = _modus_rotl32(d, 8)
		c += d; b ~= c; b = _modus_rotl32(b, 7)
		return a, b, c, d
	}

	p1, p5, p9, p13 := qr(CHACHA_SIGMA_1, s5, s9, s13)
	p2, p6, p10, p14 := qr(CHACHA_SIGMA_2, s6, s10, s14)
	p3, p7, p11, p15 := qr(CHACHA_SIGMA_3, s7, s11, s15)

	for g := 0; g < 4; g += 1 {
		for n := 0; n < 4; n += 1 {
			p0, p4, p8, p12 := qr(CHACHA_SIGMA_0, s4, s8, s12)

			x0, x5, x10, x15 := qr(p0, p5, p10, p15)
			x1, x6, x11, x12 := qr(p1, p6, p11, p12)
			x2, x7, x8, x13 := qr(p2, p7, p8, p13)
			x3, x4, x9, x14 := qr(p3, p4, p9, p14)

			for i := CHACHA_ROUNDS - 2; i > 0; i -= 2 {
				x0, x4, x8, x12 = qr(x0, x4, x8, x12)
				x1, x5, x9, x13 = qr(x1, x5, x9, x13)
				x2, x6, x10, x14 = qr(x2, x6, x10, x14)
				x3, x7, x11, x15 = qr(x3, x7, x11, x15)

				x0, x5, x10, x15 = qr(x0, x5, x10, x15)
				x1, x6, x11, x12 = qr(x1, x6, x11, x12)
				x2, x7, x8, x13 = qr(x2, x7, x8, x13)
				x3, x4, x9, x14 = qr(x3, x4, x9, x14)
			}

			STRIDE :: 4
			d_ := dst[n:]
			d_[STRIDE*0]  = x0
			d_[STRIDE*1]  = x1
			d_[STRIDE*2]  = x2
			d_[STRIDE*3]  = x3
			d_[STRIDE*4]  = x4 + s4
			d_[STRIDE*5]  = x5 + s5
			d_[STRIDE*6]  = x6 + s6
			d_[STRIDE*7]  = x7 + s7
			d_[STRIDE*8]  = x8 + s8
			d_[STRIDE*9]  = x9 + s9
			d_[STRIDE*10] = x10 + s10
			d_[STRIDE*11] = x11 + s11
			d_[STRIDE*12] = x12
			d_[STRIDE*13] = x13 + s13
			d_[STRIDE*14] = x14 + s14
			d_[STRIDE*15] = x15 + s15

			s12 += 1
		}
		dst = dst[16*4:]
	}
	_modus_rand_off = 0
}

_rand_bytes :: proc "contextless" (dst: []byte) {
	if len(dst) == 0 {
		return
	}
	_modus_lock(&_modus_rand_lock)
	defer _modus_unlock(&_modus_rand_lock)

	if !_modus_rand_seeded {
		ctx := _modus_context_record()
		seed_words := ([^]u64)(raw_data(_modus_rand_buf[RNG_OUTPUT_PER_ITER:]))
		for i in 0 ..< _MODUS_CONTEXT_VALUE_SEED_COUNT {
			seed_words[i] = intrinsics.volatile_load(&ctx.values[_MODUS_CONTEXT_VALUE_SEED + i])
			// Scrub the seed from the context page immediately on first read.
			intrinsics.volatile_store(&ctx.values[_MODUS_CONTEXT_VALUE_SEED + i], 0)
		}
		_modus_rand_seeded = true
		_modus_chacha8_refill()
	}

	out := dst
	for len(out) > 0 {
		if _modus_rand_off >= RNG_OUTPUT_PER_ITER {
			_modus_chacha8_refill()
		}
		avail := RNG_OUTPUT_PER_ITER - _modus_rand_off
		n := min(len(out), avail)
		intrinsics.mem_copy_non_overlapping(raw_data(out), raw_data(_modus_rand_buf[_modus_rand_off:]), n)
		intrinsics.mem_zero(raw_data(_modus_rand_buf[_modus_rand_off:]), n)
		_modus_rand_off += n
		out = out[n:]
	}
}

_stderr_write :: proc "contextless" (data: []byte) -> (int, _OS_Errno) {
	if len(data) == 0 {
		return 0, 0
	}
	log_handle := _modus_context_record().handles[_MODUS_CONTEXT_LOG]
	if log_handle == 0 {
		return len(data), 0
	}
	written := 0
	for written < len(data) {
		chunk := min(len(data) - written, _MODUS_LOG_TEXT_BYTES_MOST)
		_, status := _modus_call(
			.Log,
			u64(log_handle),
			u64(uintptr(&data[written])),
			u64(chunk),
			u64(_Modus_Log_Level.Error),
			0,
			0,
		)
		if status != .Succeeded {
			return written, _OS_Errno(status)
		}
		written += chunk
	}
	return written, 0
}

_exit :: proc "contextless" (code: int) -> ! {
	outcome := _Modus_Stop_Outcome.Done if code == 0 else _Modus_Stop_Outcome.Failed
	kr := _modus_kernel_ring()
	cap := int(kr.commands.mask + 1)

	for round := 0; ; round += 1 {
		for _ in 0 ..< cap {
			if _, popped := _modus_ring_pop(&kr.completions); !popped {
				break
			}
		}
		cmds_empty := _modus_ring_empty(&kr.commands)
		comps_empty := _modus_ring_empty(&kr.completions)
		if cmds_empty && comps_empty {
			if _, status := _modus_call(.Process_Stop, 0, u64(outcome), 0); status == .Succeeded {
				for {}
			}
			break
		}
		if !comps_empty || round >= cap {
			break
		}
		_modus_system_enter(0)
	}

	// Fault on read-only TIME_ADDRESS if the kernel ring cannot accept Process_Stop.
	intrinsics.volatile_store((^u64)(uintptr(_MODUS_TIME_ADDRESS)), 0)
	for {}
}
