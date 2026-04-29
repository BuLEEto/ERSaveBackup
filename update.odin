package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import "gui:skald"

update :: proc(s: State, msg: Msg) -> (State, skald.Command(Msg)) {
	out := s

	switch v in msg {
	case Tick:
		out.ticking = true
		return on_tick(out)

	case Select_Profile:
		out.selected_id = u64(v)
		return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))

	case New_Profile_Open:
		free_draft(&out.draft)
		out.draft = fresh_draft()
		out.creating = true
		out.editing_id = 0
		return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))

	case Edit_Profile_Open:
		free_draft(&out.draft)
		out.draft = fresh_draft()
		if p := find_profile(&out, u64(v)); p != nil {
			delete(out.draft.name)
			delete(out.draft.custom_path)
			delete(out.draft.backup_dir)
			out.draft.name             = strings.clone(p.name)
			out.draft.custom_path      = strings.clone(p.source_file)
			out.draft.selected_save    = -1
			out.draft.backup_dir       = strings.clone(p.backup_dir)
			out.draft.interval_minutes = p.interval_minutes
			out.draft.max_backups      = p.max_backups
			out.draft.enabled          = p.enabled
			out.editing_id             = p.id
			out.creating               = true
		}
		return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))

	case New_Profile_Cancel:
		out.creating = false
		out.editing_id = 0
		free_draft(&out.draft)
		out.draft = fresh_draft()
		return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))

	case New_Profile_Submit:
		return on_submit_new(out)

	case Delete_Profile_Ask:
		out.deleting_id = u64(v)
		return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))

	case Delete_Profile_Cancel:
		out.deleting_id = 0
		return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))

	case Delete_Profile:
		out.deleting_id = 0
		return on_delete(out, u64(v))

	case Manual_Backup:
		return on_manual_backup(out, u64(v))

	case Restore_Open:
		return on_restore_open(out, u64(v))

	case Restore_Close:
		return on_restore_close(out)

	case Restore_Ask:
		// Clone the path off the entries slice so it survives even if the
		// picker list is refreshed while the confirm dialog is open.
		delete(out.restore_confirm_path)
		out.restore_confirm_path = strings.clone(v.path)
		return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))

	case Restore_Cancel:
		delete(out.restore_confirm_path)
		out.restore_confirm_path = ""
		return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))

	case Restore_Confirm:
		return on_restore_confirm(out)

	case Toggle_Enabled:
		if p := find_profile(&out, u64(v)); p != nil {
			p.enabled = !p.enabled
			save_profiles(out.profiles[:])
			append_log(&out, fmt.tprintf("%s: auto-backup %s", p.name, p.enabled ? "enabled" : "disabled"))
		}
		return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))

	case Set_Interval:
		if p := find_profile(&out, v.id); p != nil {
			p.interval_minutes = v.minutes
			save_profiles(out.profiles[:])
		}
		return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))

	case Draft_Name:
		delete(out.draft.name)
		out.draft.name = strings.clone(string(v))
		return out, {}

	case Draft_Backup_Dir:
		delete(out.draft.backup_dir)
		out.draft.backup_dir = strings.clone(string(v))
		return out, {}

	case Draft_Max_Backups:
		n, ok := strconv.parse_int(string(v))
		if ok && n > 0 && n <= 1000 { out.draft.max_backups = n }
		return out, {}

	case Draft_Enabled:
		out.draft.enabled = bool(v)
		return out, {}

	case Draft_Interval:
		n, ok := strconv.parse_int(string(v))
		if ok && n >= 0 && n <= 1440 { out.draft.interval_minutes = n }
		return out, {}

	case Draft_Select_Save:
		out.draft.selected_save = int(v)
		delete(out.draft.custom_path)
		out.draft.custom_path = strings.clone("")
		// Pre-fill backup dir if empty
		if len(out.draft.backup_dir) == 0 && int(v) >= 0 && int(v) < len(out.detected_saves) {
			ds := out.detected_saves[int(v)]
			suggested := suggest_backup_dir(ds, out.draft.name, context.temp_allocator)
			delete(out.draft.backup_dir)
			out.draft.backup_dir = strings.clone(suggested)
		}
		return out, {}

	case Draft_Custom_Path:
		delete(out.draft.custom_path)
		out.draft.custom_path = strings.clone(string(v))
		out.draft.selected_save = -1
		return out, {}

	case Open_File_Dialog_Browse:
		// SDL3's filtered file-dialog code is unreliable on some Linux
		// desktops (silent drop on Pop!_OS COSMIC, dbus crash even with
		// the zenity backend forced). Pass nil; an Elden Ring save
		// folder only contains a handful of files anyway.
		return out, skald.cmd_open_file_dialog(nil, browse_to_msg)

	case File_Dialog_Browse_Result:
		if !v.cancelled && len(v.path) > 0 {
			delete(out.draft.custom_path)
			out.draft.custom_path = strings.clone(v.path)
			out.draft.selected_save = -1
		}
		// path from dialog is persistent-heap; we cloned, so free the original.
		if len(v.path) > 0 do delete(v.path)
		return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))

	case Open_File_Dialog_Backup_Dir:
		return out, skald.cmd_open_folder_dialog(backup_dir_to_msg)

	case File_Dialog_Backup_Dir_Result:
		if !v.cancelled && len(v.path) > 0 {
			delete(out.draft.backup_dir)
			out.draft.backup_dir = strings.clone(v.path)
		}
		if len(v.path) > 0 do delete(v.path)
		return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))

	case Rescan_Saves:
		for ds in out.detected_saves {
			delete(ds.path); delete(ds.filename); delete(ds.app_id)
			delete(ds.steam_user_id); delete(ds.character_hint)
			for s in ds.slots do delete(s.name)
			delete(ds.slots)
		}
		delete(out.detected_saves)
		out.detected_saves = detect_all_saves()
		append_log(&out, fmt.tprintf("Rescanned — %d saves found", len(out.detected_saves)))
		return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))

	case Noop:
		return out, {}
	}

	return out, {}
}

browse_to_msg :: proc(r: skald.File_Dialog_Result) -> Msg {
	return File_Dialog_Browse_Result{path = r.path, cancelled = r.cancelled}
}

backup_dir_to_msg :: proc(r: skald.File_Dialog_Result) -> Msg {
	return File_Dialog_Backup_Dir_Result{path = r.path, cancelled = r.cancelled}
}

on_tick :: proc(s: State) -> (State, skald.Command(Msg)) {
	out := s
	now_ns := time.now()._nsec

	// Rate-limit ER process check to once every ER_CHECK_NS.
	if now_ns - out.last_er_check_ns >= ER_CHECK_NS {
		prev := out.er_running
		out.er_running = is_elden_ring_running()
		out.last_er_check_ns = now_ns
		if prev != out.er_running {
			append_log(&out, out.er_running ? "Elden Ring detected" : "Elden Ring closed")
		}
	}

	// Walk profiles, fire auto-backups.
	now_unix := time.to_unix_seconds(time.now())
	for &p in out.profiles {
		if !p.enabled do continue
		if p.interval_minutes <= 0 do continue
		if !out.er_running do continue

		elapsed_sec := now_unix - p.last_backup_unix
		if elapsed_sec >= i64(p.interval_minutes) * 60 {
			do_backup(&out, &p, false)
		}
	}

	return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))
}

on_submit_new :: proc(s: State) -> (State, skald.Command(Msg)) {
	out := s
	d := &out.draft

	if len(strings.trim_space(d.name)) == 0 {
		delete(d.error); d.error = strings.clone("Name is required")
		return out, {}
	}
	if len(strings.trim_space(d.backup_dir)) == 0 {
		delete(d.error); d.error = strings.clone("Backup destination is required")
		return out, {}
	}

	source_path: string
	if d.selected_save >= 0 && d.selected_save < len(out.detected_saves) {
		source_path = out.detected_saves[d.selected_save].path
	} else if len(d.custom_path) > 0 {
		source_path = d.custom_path
	} else {
		delete(d.error); d.error = strings.clone("Pick a save file (or Browse…)")
		return out, {}
	}

	char_hint: string
	if d.selected_save >= 0 && d.selected_save < len(out.detected_saves) {
		char_hint = out.detected_saves[d.selected_save].character_hint
	}

	if out.editing_id != 0 {
		// Editing an existing profile: mutate in place, preserving id
		// and last_backup_unix. If the source changed to a detected save
		// we pick up its character_hint; otherwise keep the old summary.
		if p := find_profile(&out, out.editing_id); p != nil {
			delete(p.name);        p.name        = strings.clone(d.name)
			delete(p.source_file); p.source_file = strings.clone(source_path)
			delete(p.backup_dir);  p.backup_dir  = strings.clone(d.backup_dir)
			p.interval_minutes = d.interval_minutes
			p.max_backups      = d.max_backups
			p.enabled          = d.enabled
			if len(char_hint) > 0 {
				delete(p.character_summary)
				p.character_summary = strings.clone(char_hint)
			}
			save_profiles(out.profiles[:])
			append_log(&out, fmt.tprintf("Updated profile: %s", p.name))
		}
		out.creating   = false
		out.editing_id = 0
		free_draft(&out.draft)
		out.draft = fresh_draft()
		return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))
	}

	p := Profile{
		id                = now_id(),
		name              = strings.clone(d.name),
		source_file       = strings.clone(source_path),
		backup_dir        = strings.clone(d.backup_dir),
		interval_minutes  = d.interval_minutes,
		max_backups       = d.max_backups,
		enabled           = d.enabled,
		last_backup_unix  = 0,
		character_summary = strings.clone(char_hint),
	}
	append(&out.profiles, p)
	out.selected_id = p.id
	save_profiles(out.profiles[:])
	append_log(&out, fmt.tprintf("Created profile: %s", p.name))

	out.creating = false
	free_draft(&out.draft)
	out.draft = fresh_draft()

	return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))
}

on_delete :: proc(s: State, id: u64) -> (State, skald.Command(Msg)) {
	out := s
	for p, i in out.profiles {
		if p.id == id {
			// Clone before delete: `p.name`, `out.profiles[i].name` and
			// `name` all alias the same bytes, and `name` is read again
			// in the log line below.
			name := strings.clone(p.name, context.temp_allocator)
			delete(out.profiles[i].name)
			delete(out.profiles[i].source_file)
			delete(out.profiles[i].backup_dir)
			delete(out.profiles[i].character_summary)
			ordered_remove(&out.profiles, i)
			if out.selected_id == id do out.selected_id = 0
			if out.restoring_id == id {
				out.restoring_id = 0
				delete(out.restore_confirm_path); out.restore_confirm_path = ""
				if out.restore_entries != nil {
					free_backup_entries(out.restore_entries)
					out.restore_entries = nil
				}
			}
			save_profiles(out.profiles[:])
			append_log(&out, fmt.tprintf("Deleted profile: %s", name))
			break
		}
	}
	return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))
}

on_manual_backup :: proc(s: State, id: u64) -> (State, skald.Command(Msg)) {
	out := s
	if p := find_profile(&out, id); p != nil {
		do_backup(&out, p, true)
	}
	return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))
}

do_backup :: proc(s: ^State, p: ^Profile, manual: bool) {
	r := make_backup(p, s.tz, context.allocator)
	if !r.ok {
		append_log(s, fmt.tprintf("%s: backup failed — %s", p.name, r.err))
		delete(r.timestamp); delete(r.err); delete(r.backup_path)
		return
	}
	p.last_backup_unix = time.to_unix_seconds(time.now())
	prune_backups(p)
	if removed := prune_prerestore(p); removed > 0 {
		append_log(s, fmt.tprintf("%s: pruned %d stale pre-restore snapshot(s)", p.name, removed))
	}
	save_profiles(s.profiles[:])
	tag := manual ? "manual" : "auto"
	when_str := format_local_time(p.last_backup_unix, s.tz)
	append_log(s, fmt.tprintf("%s: %s backup — %s", p.name, tag, when_str))
	delete(r.timestamp)
	delete(r.err)
	delete(r.backup_path)
}

on_restore_open :: proc(s: State, id: u64) -> (State, skald.Command(Msg)) {
	out := s
	if p := find_profile(&out, id); p != nil {
		// Refresh entries; free any previous set first.
		if out.restore_entries != nil {
			free_backup_entries(out.restore_entries)
			out.restore_entries = nil
		}
		out.restore_entries = list_backups(p, out.tz)
		out.restoring_id = id
	}
	return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))
}

on_restore_close :: proc(s: State) -> (State, skald.Command(Msg)) {
	out := s
	out.restoring_id = 0
	delete(out.restore_confirm_path); out.restore_confirm_path = ""
	if out.restore_entries != nil {
		free_backup_entries(out.restore_entries)
		out.restore_entries = nil
	}
	return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))
}

on_restore_confirm :: proc(s: State) -> (State, skald.Command(Msg)) {
	out := s
	if out.restoring_id == 0 || len(out.restore_confirm_path) == 0 {
		return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))
	}
	if out.er_running {
		append_log(&out, "Restore blocked — Elden Ring is running")
		delete(out.restore_confirm_path); out.restore_confirm_path = ""
		return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))
	}

	p := find_profile(&out, out.restoring_id)
	if p == nil {
		return on_restore_close(out)
	}

	// Snapshot the current live save first.
	snap := make_prerestore_snapshot(p, out.tz, context.allocator)
	if !snap.ok {
		append_log(&out, fmt.tprintf("%s: pre-restore snapshot failed — %s", p.name, snap.err))
		delete(snap.timestamp); delete(snap.err); delete(snap.backup_path)
		delete(out.restore_confirm_path); out.restore_confirm_path = ""
		return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))
	}
	delete(snap.timestamp); delete(snap.err); delete(snap.backup_path)

	// Perform the restore.
	ok, err := restore_backup(p, out.restore_confirm_path)
	if !ok {
		append_log(&out, fmt.tprintf("%s: restore failed — %s", p.name, err))
		delete(err)
	} else {
		append_log(&out, fmt.tprintf("%s: restored %s", p.name, filepath.base(out.restore_confirm_path)))
	}

	// Close both dialogs and refresh entries (new pre-restore file appeared).
	delete(out.restore_confirm_path); out.restore_confirm_path = ""
	if out.restore_entries != nil {
		free_backup_entries(out.restore_entries)
		out.restore_entries = nil
	}
	out.restoring_id = 0
	return out, skald.cmd_delay(TICK_SECONDS, Msg(Tick{}))
}

suggest_backup_dir :: proc(ds: Detected_Save, name: string, allocator := context.allocator) -> string {
	home: string
	when ODIN_OS == .Windows {
		home = os.get_env("USERPROFILE", allocator)
		if len(home) == 0 do home = strings.clone("C:\\", allocator)
	} else {
		home = os.get_env("HOME", allocator)
		if len(home) == 0 do home = strings.clone(".", allocator)
	}
	label := len(strings.trim_space(name)) > 0 ? name : ds.filename
	suggested, _ := filepath.join({home, "ERBackups", label}, allocator)
	return suggested
}
