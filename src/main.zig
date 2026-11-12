const r4os = @import("r4os");

const export_path = "C:\\HWDIAG.TXT";
const report_capacity: usize = 64 * 1024;

const Profile = enum {
    min,
    std,
    full,
    export_report,
};

const App = struct {
    sys: r4os.r4sys.Context,
    app: *r4os.App2,
    dev: r4os.r4dev.Context,
    files: r4os.Files,
    records: []const r4os.abi.DeviceInventoryRecord = &.{},
    inventory: r4os.abi.DeviceInventorySnapshotInfo = .{},

    fn init(app: *r4os.App2) ?App {
        return .{ .app = app, .sys = app.system(), .dev = app.devicesLowLevel() orelse return null, .files = app.files() orelse return null };
    }

    fn run(self: *App) i32 {
        const profile = parseProfile(self.app) orelse return 2;
        const provider = self.app.deviceSnapshotProvider() catch return 1;
        var sizing = r4os.device_snapshot.Snapshot.init(.{}, 0, provider) catch return 1;
        defer _ = sizing.close() catch {};
        const needed = sizing.capture(false) catch return 1;
        if (needed.status != @intFromEnum(r4os.device_snapshot.Status.capacity) and
            needed.status != @intFromEnum(r4os.device_snapshot.Status.complete)) return 1;
        const allocator = self.app.allocator() orelse return 1;
        const records = allocator.alloc(r4os.abi.DeviceInventoryRecord, needed.info.required_count) catch return 1;
        defer allocator.free(records);
        const bytes = @import("std").mem.sliceAsBytes(records);
        var snapshot = r4os.device_snapshot.Snapshot.init(.{ .address = @intFromPtr(bytes.ptr), .length = bytes.len }, @intCast(records.len), provider) catch return 1;
        defer _ = snapshot.close() catch {};
        const captured = snapshot.capture(false) catch return 1;
        // Capacity growth or incomplete capture never becomes a partial report.
        if (captured.status != @intFromEnum(r4os.device_snapshot.Status.complete)) return 1;
        self.records = snapshot.records() catch return 1;
        self.inventory = captured.info;
        if (profile == .export_report) return self.exportReport();
        const buffer = allocator.alloc(u8, report_capacity) catch return 1;
        defer allocator.free(buffer);
        var writer = Writer.init(buffer);
        const ok = self.buildReport(&writer, profile);
        self.sys.write(writer.bytes());
        self.sys.write("HWDIAG result: ");
        self.sys.println(if (ok and !writer.truncated) "OK" else "FAILED");
        return if (ok and !writer.truncated) 0 else 1;
    }

    fn exportReport(self: *App) i32 {
        const allocator = self.app.allocator() orelse return 1;
        const buffer = allocator.alloc(u8, report_capacity) catch return 1;
        defer allocator.free(buffer);
        var writer = Writer.init(buffer);
        const ok_report = self.buildReport(&writer, .std);
        const data = writer.bytes();
        const path = r4os.AbsoluteFilePath.parse(export_path) catch return 1;
        // Keep the established report file and format. Verify its complete
        // metadata2 snapshot and every byte, rather than just the magic prefix.
        const written: usize = switch (self.files.write(path.asZ(), data)) {
            .bytes => |count| count,
            else => 0,
        };
        const verify = allocator.alloc(u8, report_capacity) catch return 1;
        defer allocator.free(verify);
        const read = self.files.readDocumentPrefix(path.asZ(), verify, .{ .kind = r4os.abi.timeout_kind_finite, .nanoseconds = 1_000_000_000 });
        const ok = ok_report and !writer.truncated and written == data.len and switch (read) {
            .value => |value| value.file_size == data.len and value.bytes == data.len and @import("std").mem.eql(u8, data, verify[0..value.bytes]),
            .failure => false,
        };

        self.sys.write("HWDIAG export: ");
        self.sys.write(if (ok) "OK" else "FAILED");
        self.sys.write(" path=");
        self.sys.write(export_path);
        self.sys.write(" bytes=");
        self.sys.printU64(if (written > 0) @as(u64, @intCast(written)) else 0);
        self.sys.println("");
        return if (ok) 0 else 1;
    }

    fn buildReport(self: *App, writer: *Writer, profile: Profile) bool {
        writer.line("HWDIAG.R4X");
        writer.line("==========");
        writer.write("Profile: ");
        writer.line(profileName(profile));
        writer.line("");

        const hw = self.dev.hardwareSummary() orelse {
            writer.line("Hardware-Summary: not available");
            return false;
        };
        writeHardwareSummary(writer, hw);

        const inv: r4os.abi.DeviceInventorySummary = .{
            .total = self.inventory.count,
            .with_driver = self.inventory.with_driver,
            .without_driver = self.inventory.without_driver,
            .unknown = self.inventory.unknown,
        };
        writeInventorySummary(writer, inv);

        if (profile != .min) {
            writer.line("");
            writer.line("Storage controllers");
            writeFilteredRecords(self, writer, .storage);
            writer.line("");
            writer.line("USB");
            writeFilteredRecords(self, writer, .usb);
            writer.line("");
            writer.line("Display / Audio / Network");
            writeFilteredRecords(self, writer, .runtime);
            if (profile == .full) {
                writer.line("");
                writer.line("Device inventory records");
                writeRecords(self, writer, inv.total, 0, true);
            } else {
                writer.line("");
                writer.line("Device inventory sample");
                writeRecords(self, writer, inv.total, 24, false);
            }
        }

        writer.line("");
        writer.line("Cross references: SPECTRA LOGS BOOT for kernel logs, SPECTRA METRICS BOOT for loader maps, SPECTRA METRICS MEMORY for memory, DEVMGR.R4X for device details.");
        return true;
    }
};

pub fn r4_app_main(raw_app: *r4os.App2) i32 {
    var app = App.init(raw_app) orelse return r4os.abi.err_no_group;
    return app.run();
}

const RecordFilter = enum {
    storage,
    usb,
    runtime,
};

const bus_platform: u8 = 0;
const bus_acpi: u8 = 1;
const bus_pci: u8 = 2;
const bus_pcie: u8 = 3;
const bus_storage: u8 = 4;
const bus_display: u8 = 5;
const bus_audio: u8 = 6;
const bus_input: u8 = 7;
const bus_driver: u8 = 8;
const bus_network: u8 = 9;
const bus_usb: u8 = 10;
const bus_protocol: u8 = 11;

fn writeHardwareSummary(writer: *Writer, hw: r4os.abi.HardwareSummary) void {
    writer.line("Hardware profile");
    writer.fieldText("Bus", busSummary(hw));
    writer.fieldDec("PCIe devices", hw.pcie_devices);
    writer.fieldDec("Legacy PCI devices", hw.legacy_pci_devices);
    writer.fieldText("ACPI", if ((hw.flags & r4os.abi.hardware_summary_flag_acpi) != 0) "active" else "missing");
    writer.fieldDec("ACPI tables", hw.acpi_tables);
    writer.fieldDec("ACPI invalid", hw.acpi_invalid_tables);
    writer.fieldText("IRQ controller", irqName(hw.irq_controller));
    writer.fieldText("Timer", timerName(hw.timer_backend));
    writer.fieldDec("LAPIC", hw.lapic_count);
    writer.fieldDec("IOAPIC", hw.ioapic_count);
    writer.fieldDec("IRQ ISO", hw.iso_count);
    writer.fieldDec64("HPET Hz", hw.hpet_frequency_hz);
    writer.fieldDec("CPU logical", hw.cpu_logical_processors);
    writer.fieldDec("CPU phys bits", hw.cpu_physical_address_bits);
    writer.fieldDec("CPU virt bits", hw.cpu_virtual_address_bits);
    writer.fieldDec("Storage controllers", hw.storage_controllers);
    writer.fieldDec("Block devices", hw.block_devices);
    writer.fieldDec("USB controllers", hw.usb_controllers);
    writer.fieldDec("USB devices", hw.usb_devices);
    writer.fieldDec("USB configured", hw.usb_configured);
    writer.fieldDec("Network controllers", hw.network_controllers);
    writer.fieldDec("Display controllers", hw.display_controllers);
    writer.fieldDec("HDA controllers", hw.hda_controllers);
    writer.fieldDec("Driver records", hw.driver_records);
    writer.fieldDec("Protocol records", hw.protocol_records);
}

fn writeInventorySummary(writer: *Writer, inv: r4os.abi.DeviceInventorySummary) void {
    writer.line("");
    writer.line("Device inventory");
    writer.fieldDec("Total", inv.total);
    writer.fieldDec("With driver", inv.with_driver);
    writer.fieldDec("Without driver", inv.without_driver);
    writer.fieldDec("Unknown", inv.unknown);
    writer.fieldText("Truncated", if (inv.truncated != 0) "yes" else "no");
}

fn writeFilteredRecords(app: *App, writer: *Writer, filter: RecordFilter) void {
    var count: u32 = 0;
    for (app.records, 0..) |rec, index| {
        if (!matchesFilter(rec, filter)) continue;
        writeRecord(writer, @intCast(index), rec);
        count += 1;
    }
    if (count == 0) writer.line("  none");
}

fn writeRecords(app: *App, writer: *Writer, total: u32, limit: u32, all: bool) void {
    const max = if (all or limit == 0 or total <= limit) total else limit;
    var index: u32 = 0;
    while (index < max) : (index += 1) {
        const rec = app.records[index];
        writeRecord(writer, @intCast(index), rec);
    }
    if (max < total) {
        writer.write("  ... ");
        writer.dec(total - max);
        writer.line(" more records in FULL");
    }
}

fn writeRecord(writer: *Writer, index: u32, rec: r4os.abi.DeviceInventoryRecord) void {
    writer.write("  #");
    writer.dec(index);
    writer.write(" ");
    writer.write(busName(rec.bus));
    writer.write(" ");
    writer.hex2(rec.bus_no);
    writer.write(":");
    writer.hex2(rec.device_no);
    writer.write(".");
    writer.dec(rec.function_no);
    writer.write(" class=");
    writer.hex2(rec.class_code);
    writer.write("/");
    writer.hex2(rec.subclass);
    writer.write("/");
    writer.hex2(rec.prog_if);
    writer.write(" id=");
    writer.hex4(rec.vendor_id);
    writer.write(":");
    writer.hex4(rec.device_id);
    writer.write(" ");
    writer.writeZ(rec.name[0..]);
    writer.write(" driver=");
    writer.writeZ(rec.driver[0..]);
    writer.write(" status=");
    writer.writeZ(rec.status[0..]);
    writer.write(" binding=");
    writer.write(bindingName(rec.binding));
    const note = spanZ(rec.note[0..]);
    if (note.len != 0) {
        writer.write(" note=");
        writer.write(note);
    }
    writer.line("");
}

fn matchesFilter(rec: r4os.abi.DeviceInventoryRecord, filter: RecordFilter) bool {
    return switch (filter) {
        .storage => rec.bus == bus_storage or rec.class_code == 0x01,
        .usb => rec.bus == bus_usb or rec.class_code == 0x0C and rec.subclass == 0x03,
        .runtime => rec.bus == bus_display or rec.bus == bus_audio or rec.bus == bus_network or rec.bus == bus_driver or rec.bus == bus_protocol or rec.class_code == 0x03 or rec.class_code == 0x04 or rec.class_code == 0x02,
    };
}

fn parseProfile(app: *r4os.App2) ?Profile {
    var failure: r4os.arguments.Failure = .{};
    var cursor = app.argCursor(.{ .quotes = 0 }, &failure) catch return null;
    var profile: Profile = .std;
    while (cursor.next() catch return null) |token| {
        const text = token.bytes(app.args()) catch return null;
        // Preserve the original aliases and priority when flags are combined.
        if (containsIgnoreCase(text, "EXPORT")) profile = .export_report
        else if (containsIgnoreCase(text, "FULL") and profile != .export_report) profile = .full
        else if (containsIgnoreCase(text, "MIN") and profile == .std) profile = .min;
    }
    return profile;
}

fn profileName(profile: Profile) []const u8 {
    return switch (profile) {
        .min => "MIN",
        .std => "STD",
        .full => "FULL",
        .export_report => "EXPORT",
    };
}

fn busSummary(hw: r4os.abi.HardwareSummary) []const u8 {
    if ((hw.flags & r4os.abi.hardware_summary_flag_pcie) != 0) return "PCIe ECAM";
    if ((hw.flags & r4os.abi.hardware_summary_flag_legacy_pci) != 0) return "Legacy PCI";
    return "none";
}

fn irqName(value: u8) []const u8 {
    return switch (value) {
        1 => "PIC",
        2 => "IOAPIC",
        else => "unknown",
    };
}

fn timerName(value: u8) []const u8 {
    return switch (value) {
        @intFromEnum(r4os.abi.TimeBackend.pit) => "PIT",
        @intFromEnum(r4os.abi.TimeBackend.hpet) => "HPET",
        @intFromEnum(r4os.abi.TimeBackend.lapic) => "LAPIC",
        else => "unknown",
    };
}

fn busName(value: u8) []const u8 {
    return switch (value) {
        bus_platform => "platform",
        bus_acpi => "acpi",
        bus_pci => "pci",
        bus_pcie => "pcie",
        bus_storage => "storage",
        bus_display => "display",
        bus_audio => "audio",
        bus_input => "input",
        bus_driver => "driver",
        bus_network => "network",
        bus_usb => "usb",
        bus_protocol => "protocol",
        else => "unknown",
    };
}

fn bindingName(value: u8) []const u8 {
    return switch (value) {
        0 => "driver",
        1 => "none",
        2 => "unknown",
        else => "?",
    };
}

const Writer = struct {
    data: []u8,
    len: usize = 0,
    truncated: bool = false,

    fn init(data: []u8) Writer {
        return .{ .data = data };
    }

    fn bytes(self: *const Writer) []const u8 {
        return self.data[0..self.len];
    }

    fn write(self: *Writer, text: []const u8) void {
        if (text.len == 0) return;
        const remaining = self.data.len - self.len;
        if (remaining == 0) {
            self.truncated = true;
            return;
        }
        const copy_len = if (text.len <= remaining) text.len else remaining;
        var i: usize = 0;
        while (i < copy_len) : (i += 1) self.data[self.len + i] = text[i];
        self.len += copy_len;
        if (copy_len != text.len) self.truncated = true;
    }

    fn line(self: *Writer, text: []const u8) void {
        self.write(text);
        self.write("\r\n");
    }

    fn fieldText(self: *Writer, name: []const u8, value: []const u8) void {
        self.write("  ");
        self.write(name);
        self.write(": ");
        self.line(value);
    }

    fn fieldDec(self: *Writer, name: []const u8, value: anytype) void {
        self.write("  ");
        self.write(name);
        self.write(": ");
        self.dec(@as(u64, @intCast(value)));
        self.write("\r\n");
    }

    fn fieldDec64(self: *Writer, name: []const u8, value: u64) void {
        self.write("  ");
        self.write(name);
        self.write(": ");
        self.dec(value);
        self.write("\r\n");
    }

    fn writeZ(self: *Writer, value: []const u8) void {
        const text = spanZ(value);
        self.write(if (text.len == 0) "-" else text);
    }

    fn dec(self: *Writer, value: u64) void {
        var tmp: [20]u8 = undefined;
        var n = value;
        var pos: usize = tmp.len;
        if (n == 0) {
            self.write("0");
            return;
        }
        while (n != 0) {
            pos -= 1;
            tmp[pos] = @as(u8, @intCast(n % 10)) + '0';
            n /= 10;
        }
        self.write(tmp[pos..]);
    }

    fn hex2(self: *Writer, value: u8) void {
        self.write(&[_]u8{ hexDigit(value >> 4), hexDigit(value & 0xF) });
    }

    fn hex4(self: *Writer, value: u16) void {
        self.write(&[_]u8{
            hexDigit(@as(u8, @intCast((value >> 12) & 0xF))),
            hexDigit(@as(u8, @intCast((value >> 8) & 0xF))),
            hexDigit(@as(u8, @intCast((value >> 4) & 0xF))),
            hexDigit(@as(u8, @intCast(value & 0xF))),
        });
    }
};

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'A' + (value - 10);
}

fn spanZ(value: []const u8) []const u8 {
    var len: usize = 0;
    while (len < value.len and value[len] != 0) : (len += 1) {}
    return value[0..len];
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (asciiUpper(haystack[i + j]) != asciiUpper(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

fn asciiUpper(ch: u8) u8 {
    return if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
}
