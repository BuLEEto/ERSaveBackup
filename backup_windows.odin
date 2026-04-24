#+build windows
package main

import win "core:sys/windows"

// Walk the process list via Toolhelp32 rather than spawning `tasklist`.
// Spawning a console child from a GUI-subsystem app makes Windows pop up a
// fresh conhost window each time — visible to the user as random terminal
// flashes on the tick-rate cadence. This API is in-process, no child.
is_elden_ring_running :: proc() -> bool {
	target := `eldenring.exe`

	snap := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0)
	if snap == win.INVALID_HANDLE_VALUE do return false
	defer win.CloseHandle(snap)

	entry: win.PROCESSENTRY32W
	entry.dwSize = size_of(win.PROCESSENTRY32W)

	if !win.Process32FirstW(snap, &entry) do return false

	for {
		if wchar_equal_ascii_nocase(entry.szExeFile[:], target) do return true
		if !win.Process32NextW(snap, &entry) do break
	}
	return false
}

// wchar_equal_ascii_nocase compares a null-terminated WCHAR buffer to an
// ASCII string, case-insensitively. Non-ASCII chars in the wide buffer
// cannot match and return false immediately. No allocation.
wchar_equal_ascii_nocase :: proc(wide: []u16, ascii: string) -> bool {
	// Length in wide chars up to the null terminator.
	n := 0
	for n < len(wide) && wide[n] != 0 do n += 1
	if n != len(ascii) do return false
	for i in 0 ..< n {
		w := wide[i]
		if w >= 0x80 do return false
		wc := u8(w)
		ac := ascii[i]
		if wc >= 'A' && wc <= 'Z' do wc += 'a' - 'A'
		if ac >= 'A' && ac <= 'Z' do ac += 'a' - 'A'
		if wc != ac do return false
	}
	return true
}
