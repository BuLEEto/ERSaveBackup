package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"

Backup_Result :: struct {
	ok:         bool,
	timestamp:  string,
	err:        string,
	backup_path: string,
}

Backup_Entry :: struct {
	path:          string, // owned by the returned slice's allocator
	stamp_unix:    i64,    // parsed from filename, 0 if unparseable
	is_prerestore: bool,
}

PRERESTORE_MARKER :: "_prerestore_"
PRERESTORE_TTL_SEC :: i64(7 * 24 * 60 * 60) // 1 week

make_backup :: proc(profile: ^Profile, tz: ^datetime.TZ_Region, allocator := context.allocator) -> Backup_Result {
	return make_backup_tagged(profile, tz, "", allocator)
}

make_prerestore_snapshot :: proc(profile: ^Profile, tz: ^datetime.TZ_Region, allocator := context.allocator) -> Backup_Result {
	return make_backup_tagged(profile, tz, "prerestore_", allocator)
}

make_backup_tagged :: proc(profile: ^Profile, tz: ^datetime.TZ_Region, tag: string, allocator := context.allocator) -> Backup_Result {
	now := time.now()
	dt, _ := time.time_to_datetime(now)
	if tz != nil {
		if local, ok := timezone.datetime_to_tz(dt, tz); ok do dt = local
	}
	year   := int(dt.year)
	month  := int(dt.month)
	day    := int(dt.day)
	hour   := int(dt.hour)
	minute := int(dt.minute)
	second := int(dt.second)

	timestamp := fmt.aprintf("%04d-%02d-%02d %02d:%02d:%02d",
		year, month, day, hour, minute, second, allocator = allocator)

	if !os.exists(profile.source_file) {
		return {ok = false, err = strings.clone("source file missing", allocator), timestamp = timestamp}
	}

	if !os.exists(profile.backup_dir) {
		if mk_err := os.make_directory_all(profile.backup_dir); mk_err != nil {
			return {ok = false, err = fmt.aprintf("mkdir failed: %v", mk_err, allocator = allocator), timestamp = timestamp}
		}
	}

	basename := filepath.base(profile.source_file)
	stamp := fmt.tprintf("%04d%02d%02d_%02d%02d%02d", year, month, day, hour, minute, second)
	dst_name := fmt.tprintf("%s_%s%s", basename, tag, stamp)
	dst_path, _ := filepath.join({profile.backup_dir, dst_name}, allocator)

	data, read_err := os.read_entire_file(profile.source_file, context.temp_allocator)
	if read_err != nil {
		return {ok = false, err = fmt.aprintf("read failed: %v", read_err, allocator = allocator), timestamp = timestamp}
	}

	if write_err := os.write_entire_file(dst_path, data); write_err != nil {
		return {ok = false, err = fmt.aprintf("write failed: %v", write_err, allocator = allocator), timestamp = timestamp}
	}

	return {ok = true, timestamp = timestamp, backup_path = dst_path}
}

// restore_backup overwrites the profile's source_file with the bytes of
// `backup_path`. The caller is responsible for taking a pre-restore
// snapshot first.
restore_backup :: proc(profile: ^Profile, backup_path: string, allocator := context.allocator) -> (ok: bool, err: string) {
	if !os.exists(backup_path) {
		return false, strings.clone("backup file missing", allocator)
	}
	data, read_err := os.read_entire_file(backup_path, context.temp_allocator)
	if read_err != nil {
		return false, fmt.aprintf("read failed: %v", read_err, allocator = allocator)
	}
	if write_err := os.write_entire_file(profile.source_file, data); write_err != nil {
		return false, fmt.aprintf("write failed: %v", write_err, allocator = allocator)
	}
	return true, ""
}

// parse_stamp_unix parses a "YYYYMMDD_HHMMSS" tail into a unix timestamp.
// tz is used to interpret the filename's local-time stamp; nil = UTC.
// Returns 0 on any parse failure — callers use the raw filename instead.
parse_stamp_unix :: proc(stamp: string, tz: ^datetime.TZ_Region) -> i64 {
	if len(stamp) != 15 || stamp[8] != '_' do return 0
	for i in 0 ..< 15 {
		if i == 8 do continue
		c := stamp[i]
		if c < '0' || c > '9' do return 0
	}
	to_i :: proc(s: string) -> int {
		n := 0
		for c in transmute([]u8)s do n = n*10 + int(c - '0')
		return n
	}
	year  := to_i(stamp[0:4])
	month := to_i(stamp[4:6])
	day   := to_i(stamp[6:8])
	hour  := to_i(stamp[9:11])
	min_  := to_i(stamp[11:13])
	sec   := to_i(stamp[13:15])

	dt := datetime.DateTime{
		date = {year = i64(year), month = i8(month), day = i8(day)},
		time = {hour = i8(hour), minute = i8(min_), second = i8(sec)},
		tz   = tz,
	}
	// datetime_to_utc uses dt.tz to find the local offset, so it handles
	// the case where the filename stamp is in local time.
	utc_dt, ok := timezone.datetime_to_utc(dt)
	if !ok do return 0
	t, t_ok := time.datetime_to_time(utc_dt)
	if !t_ok do return 0
	return time.to_unix_seconds(t)
}

// list_backups returns every backup file for `profile`, parsed and sorted
// newest-first. Entries are allocated in `allocator`; the caller owns each
// `path` string and the returned slice.
list_backups :: proc(profile: ^Profile, tz: ^datetime.TZ_Region, allocator := context.allocator) -> []Backup_Entry {
	basename := filepath.base(profile.source_file)
	prefix, _ := filepath.join({profile.backup_dir, basename}, context.temp_allocator)
	pattern := fmt.tprintf("%s_*", prefix)

	files, _ := filepath.glob(pattern, context.temp_allocator)
	if len(files) == 0 do return {}

	entries := make([dynamic]Backup_Entry, 0, len(files), allocator)
	for f in files {
		name := filepath.base(f)
		if len(name) <= len(basename) + 1 do continue
		tail := name[len(basename)+1:]

		is_pre := strings.has_prefix(tail, "prerestore_")
		stamp  := tail
		if is_pre do stamp = tail[len("prerestore_"):]

		append(&entries, Backup_Entry{
			path          = strings.clone(f, allocator),
			stamp_unix    = parse_stamp_unix(stamp, tz),
			is_prerestore = is_pre,
		})
	}

	slice.sort_by(entries[:], proc(a, b: Backup_Entry) -> bool {
		return a.stamp_unix > b.stamp_unix
	})
	return entries[:]
}

free_backup_entries :: proc(entries: []Backup_Entry, allocator := context.allocator) {
	for e in entries do delete(e.path, allocator)
	delete(entries, allocator)
}

prune_backups :: proc(profile: ^Profile, allocator := context.allocator) -> int {
	basename := filepath.base(profile.source_file)
	prefix, _ := filepath.join({profile.backup_dir, basename}, context.temp_allocator)
	pattern := fmt.tprintf("%s_*", prefix)

	all, _ := filepath.glob(pattern, context.temp_allocator)

	// Keep pre-restore snapshots out of the regular cap.
	regular := make([dynamic]string, 0, len(all), context.temp_allocator)
	pre_mark := fmt.tprintf("%s_prerestore_", basename)
	for f in all {
		if strings.contains(filepath.base(f), pre_mark) do continue
		append(&regular, f)
	}

	if len(regular) <= profile.max_backups do return len(regular)

	slice.sort(regular[:])

	to_delete := len(regular) - profile.max_backups
	for i in 0 ..< to_delete {
		os.remove(regular[i])
	}
	return profile.max_backups
}

// prune_prerestore deletes pre-restore snapshots older than PRERESTORE_TTL_SEC.
prune_prerestore :: proc(profile: ^Profile) -> int {
	basename := filepath.base(profile.source_file)
	prefix, _ := filepath.join({profile.backup_dir, basename}, context.temp_allocator)
	pattern := fmt.tprintf("%s_prerestore_*", prefix)
	files, _ := filepath.glob(pattern, context.temp_allocator)
	if len(files) == 0 do return 0

	now_unix := time.to_unix_seconds(time.now())
	removed := 0
	for f in files {
		info, err := os.stat(f, context.temp_allocator)
		if err != nil do continue
		mtime_unix := time.to_unix_seconds(info.modification_time)
		if now_unix - mtime_unix > PRERESTORE_TTL_SEC {
			if os.remove(f) == nil do removed += 1
		}
	}
	return removed
}

count_backups :: proc(profile: ^Profile) -> int {
	basename := filepath.base(profile.source_file)
	prefix, _ := filepath.join({profile.backup_dir, basename}, context.temp_allocator)
	pattern := fmt.tprintf("%s_*", prefix)
	files, _ := filepath.glob(pattern, context.temp_allocator)
	return len(files)
}

