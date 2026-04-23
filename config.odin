package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

Profiles_File :: struct {
	profiles: []Profile `json:"profiles"`,
}

config_dir :: proc(allocator := context.allocator) -> string {
	when ODIN_OS == .Windows {
		appdata := os.get_env("APPDATA", allocator)
		if len(appdata) > 0 {
			joined, _ := filepath.join({appdata, "ERSaveBackup"}, allocator)
			return joined
		}
		return strings.clone("ERSaveBackup", allocator)
	} else {
		xdg := os.get_env("XDG_CONFIG_HOME", allocator)
		home := os.get_env("HOME", allocator)
		if len(xdg) > 0 {
			joined, _ := filepath.join({xdg, "ERSaveBackup"}, allocator)
			return joined
		}
		if len(home) > 0 {
			joined, _ := filepath.join({home, ".config", "ERSaveBackup"}, allocator)
			return joined
		}
		return strings.clone(".", allocator)
	}
}

profiles_path :: proc(allocator := context.allocator) -> string {
	dir := config_dir(allocator)
	joined, _ := filepath.join({dir, "profiles.json"}, allocator)
	return joined
}

load_profiles :: proc(allocator := context.allocator) -> [dynamic]Profile {
	result := make([dynamic]Profile, allocator)

	path := profiles_path(context.temp_allocator)
	raw, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil do return result

	pf: Profiles_File
	if err := json.unmarshal(raw, &pf, allocator = allocator); err != nil {
		fmt.eprintln("profiles.json parse failed:", err)
		return result
	}

	for p in pf.profiles {
		append(&result, p)
	}
	return result
}

save_profiles :: proc(profiles: []Profile) {
	dir := config_dir(context.temp_allocator)
	if !os.exists(dir) {
		if err := os.make_directory_all(dir); err != nil {
			fmt.eprintln("config mkdir failed:", err)
			return
		}
	}

	pf := Profiles_File{profiles = profiles}
	data, marshal_err := json.marshal(pf, {pretty = true}, context.temp_allocator)
	if marshal_err != nil {
		fmt.eprintln("marshal failed:", marshal_err)
		return
	}

	path := profiles_path(context.temp_allocator)
	if err := os.write_entire_file(path, data); err != nil {
		fmt.eprintln("write profiles failed:", err)
	}
}

clone_profile :: proc(p: Profile, allocator := context.allocator) -> Profile {
	out := p
	out.name             = strings.clone(p.name, allocator)
	out.source_file      = strings.clone(p.source_file, allocator)
	out.backup_dir       = strings.clone(p.backup_dir, allocator)
	out.character_summary = strings.clone(p.character_summary, allocator)
	return out
}
