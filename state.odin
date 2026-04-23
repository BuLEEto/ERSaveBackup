package main

import "core:fmt"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"

Profile :: struct {
	id:                 u64    `json:"id"`,
	name:               string `json:"name"`,
	source_file:        string `json:"source_file"`,
	backup_dir:         string `json:"backup_dir"`,
	interval_minutes:   int    `json:"interval_minutes"`,
	max_backups:        int    `json:"max_backups"`,
	enabled:            bool   `json:"enabled"`,
	last_backup_unix:   i64    `json:"last_backup_unix"`,
	character_summary:  string `json:"character_summary"`,
}

Profile_Draft :: struct {
	name:             string,
	selected_save:    int, // index into state.detected_saves; -1 means "use custom_path"
	custom_path:      string, // for manual Browse pick
	backup_dir:       string,
	interval_minutes: int,
	max_backups:      int,
	enabled:          bool,
	error:            string,
}

State :: struct {
	profiles:         [dynamic]Profile,
	selected_id:      u64,
	detected_saves:   []Detected_Save,
	detect_tried:     bool,
	log_lines:        [dynamic]string,
	er_running:       bool,
	last_er_check_ns: i64,
	ticking:          bool, // true once the first Tick has been scheduled

	creating:         bool,
	editing_id:       u64,
	draft:            Profile_Draft,

	// Non-zero while a delete-confirm dialog is open, holding the id
	// of the profile that will be removed if the user confirms.
	deleting_id:      u64,

	// Non-zero while the restore picker is open.
	restoring_id:     u64,
	// Entries in the picker (owned by context.allocator; freed on close).
	restore_entries:  []Backup_Entry,
	// Non-empty while the restore confirm dialog is open: the path being
	// restored. Owned by context.allocator; cloned off restore_entries so
	// it survives if the picker list is refreshed.
	restore_confirm_path: string,

	// Local timezone, loaded once at startup. Used to format timestamps
	// for display. nil means "UTC" (either the user is in UTC or the
	// tz database couldn't be loaded).
	tz: ^datetime.TZ_Region,
}

Msg :: union {
	// tick + background
	Tick,

	// profile crud
	Select_Profile,
	New_Profile_Open,
	Edit_Profile_Open,
	New_Profile_Cancel,
	New_Profile_Submit,
	Delete_Profile_Ask,
	Delete_Profile_Cancel,
	Delete_Profile,
	Manual_Backup,
	Toggle_Enabled,
	Set_Interval,

	// restore flow
	Restore_Open,
	Restore_Close,
	Restore_Ask,
	Restore_Cancel,
	Restore_Confirm,

	// draft edits
	Draft_Name,
	Draft_Backup_Dir,
	Draft_Max_Backups,
	Draft_Enabled,
	Draft_Interval,
	Draft_Select_Save,
	Draft_Custom_Path,

	// dialogs
	Open_File_Dialog_Browse,
	File_Dialog_Browse_Result,
	Open_File_Dialog_Backup_Dir,
	File_Dialog_Backup_Dir_Result,

	// scanning
	Rescan_Saves,

	// noop for dialog dismiss when we don't want any action
	Noop,
}

Tick                       :: struct{}
Select_Profile             :: distinct u64
New_Profile_Open           :: struct{}
Edit_Profile_Open          :: distinct u64
New_Profile_Cancel         :: struct{}
New_Profile_Submit         :: struct{}
Delete_Profile_Ask         :: distinct u64
Delete_Profile_Cancel      :: struct{}
Delete_Profile             :: distinct u64
Manual_Backup              :: distinct u64
Toggle_Enabled             :: distinct u64
Set_Interval               :: struct { id: u64, minutes: int }
Restore_Open               :: distinct u64
Restore_Close              :: struct{}
Restore_Ask                :: struct { id: u64, path: string }
Restore_Cancel             :: struct{}
Restore_Confirm            :: struct{}
Draft_Name                 :: distinct string
Draft_Backup_Dir           :: distinct string
Draft_Max_Backups          :: distinct string
Draft_Enabled              :: distinct bool
Draft_Interval             :: distinct string
Draft_Select_Save          :: distinct int
Draft_Custom_Path          :: distinct string
Open_File_Dialog_Browse    :: struct{}
File_Dialog_Browse_Result  :: struct { path: string, cancelled: bool }
Open_File_Dialog_Backup_Dir :: struct{}
File_Dialog_Backup_Dir_Result :: struct { path: string, cancelled: bool }
Rescan_Saves               :: struct{}
Noop                       :: struct{}

MAX_LOG_LINES :: 8
TICK_SECONDS  :: f32(1.0)
ER_CHECK_NS   :: i64(10 * time.Second) // rate-limit pgrep to 10s

init :: proc() -> State {
	tz, _ := timezone.region_load("local")
	s := State{
		profiles       = load_profiles(),
		log_lines      = make([dynamic]string, 0, MAX_LOG_LINES),
		detected_saves = detect_all_saves(),
		detect_tried   = true,
		draft          = fresh_draft(),
		tz             = tz,
	}
	append_log(&s, fmt.tprintf("Loaded %d profile(s) from %s", len(s.profiles), profiles_path(context.temp_allocator)))
	return s
}

// format_local_time renders a unix timestamp in the user's local time
// zone as "YYYY-MM-DD HH:MM:SS TZ" (e.g. "2026-04-21 14:16:25 BST").
// Falls back to UTC if the local TZ database isn't available.
format_local_time :: proc(unix_sec: i64, tz: ^datetime.TZ_Region, allocator := context.temp_allocator) -> string {
	t := time.unix(unix_sec, 0)
	dt, ok := time.time_to_datetime(t)
	if !ok {
		return strings.clone("(invalid)", allocator)
	}
	if tz == nil {
		return fmt.aprintf("%04d-%02d-%02d %02d:%02d:%02d UTC",
			dt.year, dt.month, dt.day,
			dt.hour, dt.minute, dt.second,
			allocator = allocator)
	}
	local, tz_ok := timezone.datetime_to_tz(dt, tz)
	if !tz_ok {
		return fmt.aprintf("%04d-%02d-%02d %02d:%02d:%02d UTC",
			dt.year, dt.month, dt.day,
			dt.hour, dt.minute, dt.second,
			allocator = allocator)
	}
	abbr, _ := timezone.shortname(local)
	return fmt.aprintf("%04d-%02d-%02d %02d:%02d:%02d %s",
		local.year, local.month, local.day,
		local.hour, local.minute, local.second, abbr,
		allocator = allocator)
}

fresh_draft :: proc() -> Profile_Draft {
	return Profile_Draft{
		name             = strings.clone(""),
		selected_save    = -1,
		custom_path      = strings.clone(""),
		backup_dir       = strings.clone(""),
		interval_minutes = 10,
		max_backups      = 20,
		enabled          = true,
		error            = strings.clone(""),
	}
}

free_draft :: proc(d: ^Profile_Draft) {
	delete(d.name)
	delete(d.custom_path)
	delete(d.backup_dir)
	delete(d.error)
}

find_profile :: proc(s: ^State, id: u64) -> ^Profile {
	for &p in s.profiles {
		if p.id == id do return &p
	}
	return nil
}

selected_profile :: proc(s: ^State) -> ^Profile {
	return find_profile(s, s.selected_id)
}

append_log :: proc(s: ^State, line: string) {
	if len(s.log_lines) >= MAX_LOG_LINES {
		delete(s.log_lines[0])
		ordered_remove(&s.log_lines, 0)
	}
	append(&s.log_lines, strings.clone(line))
}

now_id :: proc() -> u64 {
	return u64(time.now()._nsec)
}
