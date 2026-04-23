package main

import "core:fmt"
import "core:os"
import "core:strings"

// Elden Ring save-file locator. Linux: walks every Steam library's
// compatdata for Elden Ring's Proton prefix and enumerates every save
// file. Windows: walks %APPDATA%/EldenRing/<steam_user>/. Lifted from
// ERBossCheckList/main.odin:1017-1205 and extended to emit per-file
// Detected_Save rows (one profile = one file).

ER_Save_Dir :: struct {
	path:   string,
	app_id: string,
}

Slot_Summary :: struct {
	slot:   int,  // 1-based display slot
	name:   string,
	level:  u32,
}

Detected_Save :: struct {
	path:           string, // full path to the save file
	filename:       string, // basename, e.g. ER0000.sl2
	app_id:         string, // Proton compatdata app id (Linux)
	steam_user_id:  string, // the 7656... folder name
	character_hint: string, // short "Slot 1 — Tarnished Lv 150" label
	slots:          []Slot_Summary, // every active character in the save
}

SAVE_EXTS :: [?]string{".sl2", ".co2", ".rd2"}

detect_all_saves :: proc(allocator := context.allocator) -> []Detected_Save {
	found := make([dynamic]Detected_Save, allocator)
	er_save_dirs := get_er_save_dirs(allocator)

	SEP :: "/" when ODIN_OS != .Windows else "\\"

	for dir_info in er_save_dirs {
		er_handle, er_err := os.open(dir_info.path)
		if er_err != nil do continue

		er_entries, er_read_err := os.read_all_directory(er_handle, allocator)
		os.close(er_handle)
		if er_read_err != nil do continue

		for user_entry in er_entries {
			uid_is_dir := user_entry.type == .Directory
			when ODIN_OS != .Windows {
				if user_entry.type == .Symlink {
					link_path := strings.concatenate({dir_info.path, SEP, user_entry.name}, allocator)
					target_info, stat_err := os.stat(link_path, allocator)
					if stat_err == nil do uid_is_dir = target_info.type == .Directory
				}
			}
			if !uid_is_dir do continue

			user_dir := strings.concatenate({dir_info.path, SEP, user_entry.name}, allocator)
			user_handle, user_err := os.open(user_dir)
			if user_err != nil do continue

			user_files, user_read_err := os.read_all_directory(user_handle, allocator)
			os.close(user_handle)
			if user_read_err != nil do continue

			for sf in user_files {
				if sf.type != .Regular do continue
				if strings.contains(sf.name, "copy") do continue
				if strings.has_suffix(sf.name, ".bak") do continue

				matched := false
				for ext in SAVE_EXTS {
					if strings.has_suffix(sf.name, ext) { matched = true; break }
				}
				if !matched do continue

				full_path := strings.concatenate({user_dir, SEP, sf.name}, allocator)

				hint, slots := parse_character_info(full_path, allocator)
				append(&found, Detected_Save{
					path           = full_path,
					filename       = strings.clone(sf.name, allocator),
					app_id         = strings.clone(dir_info.app_id, allocator),
					steam_user_id  = strings.clone(user_entry.name, allocator),
					character_hint = hint,
					slots          = slots,
				})
			}
		}
	}

	return found[:]
}

parse_character_info :: proc(path: string, allocator := context.allocator) -> (hint: string, slots: []Slot_Summary) {
	save, ok := open_save_file(path, context.temp_allocator)
	if !ok do return "", nil
	raw := get_character_slots(&save, context.temp_allocator)

	// Build in temp so the final slice is exactly `len` wide. Using a
	// cap=10 dynamic array in `allocator` and returning `buf[:]` would
	// hand callers a slice whose length lies about the backing buffer
	// size — `delete(slice)` would leak `(cap - len) * size_of(elem)`
	// bytes on every rescan.
	tmp := make([dynamic]Slot_Summary, 0, SLOT_COUNT, context.temp_allocator)
	best_level: u32 = 0
	best_name:  string
	best_slot:  int = -1
	for s in raw {
		if !s.active do continue
		append(&tmp, Slot_Summary{
			slot  = s.index + 1,
			name  = strings.clone(s.name, allocator),
			level = s.level,
		})
		if s.level > best_level {
			best_level = s.level
			best_name  = s.name
			best_slot  = s.index
		}
	}

	if len(tmp) > 0 {
		slots = make([]Slot_Summary, len(tmp), allocator)
		copy(slots, tmp[:])
	}

	if best_slot < 0 {
		return "", slots
	}
	display_name := best_name
	if len(display_name) == 0 { display_name = "(unnamed)" }
	hint = fmt.aprintf("%s Lv %d",
		display_name, best_level, allocator = allocator)
	return hint, slots
}

parse_steam_libraries :: proc(vdf_paths: []string, default_roots: []string, allocator := context.allocator) -> []string {
	libs := make([dynamic]string, allocator)

	for vdf_path in vdf_paths {
		data, read_err := os.read_entire_file(vdf_path, allocator)
		if read_err != nil do continue

		content := string(data)
		idx := 0
		for idx < len(content) {
			pos := strings.index(content[idx:], `"path"`)
			if pos < 0 do break
			idx += pos + 6

			q1 := strings.index(content[idx:], `"`)
			if q1 < 0 do break
			idx += q1 + 1
			q2 := strings.index(content[idx:], `"`)
			if q2 < 0 do break

			lib_path := content[idx:idx + q2]
			idx += q2 + 1

			is_default := false
			for dr in default_roots {
				if strings.contains(lib_path, dr) { is_default = true; break }
			}
			if is_default do continue

			append(&libs, strings.clone(lib_path, allocator))
		}
	}

	return libs[:]
}

scan_proton_roots :: proc(roots: []string, er_suffix: string, allocator := context.allocator) -> []ER_Save_Dir {
	SEP :: "/" when ODIN_OS != .Windows else "\\"
	dirs := make([dynamic]ER_Save_Dir, allocator)
	seen := make(map[string]bool, 16, allocator)

	for root in roots {
		real, real_err := os.get_absolute_path(root, allocator)
		key := real_err == nil ? real : root
		if key in seen do continue
		seen[key] = true

		compatdata_path := strings.concatenate({root, SEP, "steamapps", SEP, "compatdata"}, allocator)
		compat_handle, compat_err := os.open(compatdata_path)
		if compat_err != nil do continue

		compat_entries, compat_read_err := os.read_all_directory(compat_handle, allocator)
		os.close(compat_handle)
		if compat_read_err != nil do continue

		for app_entry in compat_entries {
			is_dir := app_entry.type == .Directory
			when ODIN_OS != .Windows {
				if app_entry.type == .Symlink {
					link_path := strings.concatenate({compatdata_path, SEP, app_entry.name}, allocator)
					target_info, stat_err := os.stat(link_path, allocator)
					if stat_err == nil do is_dir = target_info.type == .Directory
				}
			}
			if !is_dir do continue

			er_path := strings.concatenate({compatdata_path, SEP, app_entry.name, er_suffix}, allocator)
			er_handle, er_err := os.open(er_path)
			if er_err != nil do continue
			os.close(er_handle)

			append(&dirs, ER_Save_Dir{path = er_path, app_id = strings.clone(app_entry.name, allocator)})
		}
	}

	return dirs[:]
}

scan_direct_er_path :: proc(er_base: string, app_id: string, allocator := context.allocator) -> []ER_Save_Dir {
	dirs := make([dynamic]ER_Save_Dir, allocator)
	er_handle, er_err := os.open(er_base)
	if er_err != nil do return dirs[:]
	os.close(er_handle)
	append(&dirs, ER_Save_Dir{path = strings.clone(er_base, allocator), app_id = strings.clone(app_id, allocator)})
	return dirs[:]
}

when ODIN_OS == .Windows {
	get_er_save_dirs :: proc(allocator := context.allocator) -> []ER_Save_Dir {
		all_dirs := make([dynamic]ER_Save_Dir, allocator)
		SEP :: "\\"

		appdata := os.get_env("APPDATA", allocator)
		if len(appdata) > 0 {
			er_base := strings.concatenate({appdata, SEP, "EldenRing"}, allocator)
			for d in scan_direct_er_path(er_base, "1245620", allocator) {
				append(&all_dirs, d)
			}
		}
		return all_dirs[:]
	}
} else {
	get_er_save_dirs :: proc(allocator := context.allocator) -> []ER_Save_Dir {
		all_dirs := make([dynamic]ER_Save_Dir, allocator)

		home := os.get_env("HOME", allocator)
		if len(home) == 0 do return all_dirs[:]

		steam_roots := make([dynamic]string, allocator)
		append(&steam_roots, strings.concatenate({home, "/.steam/steam"}, allocator))
		append(&steam_roots, strings.concatenate({home, "/.local/share/Steam"}, allocator))
		append(&steam_roots, strings.concatenate({home, "/.var/app/com.valvesoftware.Steam/.steam/steam"}, allocator))
		append(&steam_roots, strings.concatenate({home, "/.var/app/com.valvesoftware.Steam/.local/share/Steam"}, allocator))

		vdf_paths := [?]string{
			strings.concatenate({home, "/.steam/steam/steamapps/libraryfolders.vdf"}, allocator),
			strings.concatenate({home, "/.local/share/Steam/steamapps/libraryfolders.vdf"}, allocator),
			strings.concatenate({home, "/.var/app/com.valvesoftware.Steam/.steam/steam/steamapps/libraryfolders.vdf"}, allocator),
			strings.concatenate({home, "/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/libraryfolders.vdf"}, allocator),
		}

		default_roots := [?]string{
			"/.steam/steam",
			"/.local/share/Steam",
			"/.var/app/com.valvesoftware.Steam/.steam/steam",
			"/.var/app/com.valvesoftware.Steam/.local/share/Steam",
		}
		extra_libs := parse_steam_libraries(vdf_paths[:], default_roots[:], allocator)
		for lib in extra_libs {
			append(&steam_roots, lib)
		}

		ER_APPDATA_SUFFIX :: "/pfx/drive_c/users/steamuser/AppData/Roaming/EldenRing"
		for d in scan_proton_roots(steam_roots[:], ER_APPDATA_SUFFIX, allocator) {
			append(&all_dirs, d)
		}

		return all_dirs[:]
	}
}
