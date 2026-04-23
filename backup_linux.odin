#+build linux
package main

import "core:sys/linux"

// Walk /proc/<pid>/comm via raw syscalls. Prior implementations leaked
// untracked heap memory: fork+exec pgrep burned ~1 MB per call in glibc
// bookkeeping, and os.read_dir + os.open allocate File_Info.fullpath and
// File_Impl on file_allocator() (= heap_allocator), which bypasses our
// tracking allocator. At a 10s cadence that was ~350 MB/hour. Raw syscalls
// touch no heap.
is_elden_ring_running :: proc() -> bool {
	proc_fd, op_err := linux.open("/proc", {.DIRECTORY, .CLOEXEC})
	if op_err != .NONE do return false
	defer linux.close(proc_fd)

	prefix := "/proc/"
	suffix := "/comm"
	target := "eldenring.exe"

	dents:    [4096]u8
	path_buf: [32]u8
	comm_buf: [32]u8

	for {
		n, gd_err := linux.getdents(proc_fd, dents[:])
		if gd_err != .NONE || n <= 0 do break

		offset: int
		for dirent in linux.dirent_iterate_buf(dents[:n], &offset) {
			if dirent.type != .DIR do continue
			name := linux.dirent_name(dirent)
			if len(name) == 0 || len(name) > 10 do continue

			all_digits := true
			for i in 0 ..< len(name) {
				c := name[i]
				if c < '0' || c > '9' {
					all_digits = false
					break
				}
			}
			if !all_digits do continue

			p := 0
			for i in 0 ..< len(prefix) { path_buf[p] = prefix[i]; p += 1 }
			for i in 0 ..< len(name)   { path_buf[p] = name[i];   p += 1 }
			for i in 0 ..< len(suffix) { path_buf[p] = suffix[i]; p += 1 }
			path_buf[p] = 0

			fd, o_err := linux.open(cstring(&path_buf[0]), {.CLOEXEC})
			if o_err != .NONE do continue
			rn, _ := linux.read(fd, comm_buf[:])
			linux.close(fd)
			if rn <= 0 do continue

			end := int(rn)
			if comm_buf[end-1] == '\n' do end -= 1
			if string(comm_buf[:end]) == target do return true
		}
	}
	return false
}
