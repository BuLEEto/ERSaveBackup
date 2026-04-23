#+build windows
package main

import "core:os"
import "core:strings"

is_elden_ring_running :: proc() -> bool {
	_, stdout, _, err := os.process_exec({command = {"tasklist", "/FI", "IMAGENAME eq eldenring.exe", "/NH"}}, context.temp_allocator)
	if err != nil do return false
	return strings.contains(string(stdout), "eldenring.exe")
}
