const r4os = @import("r4os");

const export_path = "C:\\HWDIAG.TXT";
const report_capacity: usize = 16 * 1024;

const Profile = enum {
    min,
    std,
    full,
    export_report,
};

const App = struct {
    sys: r4os.r4sys.Context,
    inventory: r4os.DeviceInventoryView,

    fn init(app: *r4os.App) ?App {
        return .{ .sys = app.system(), .inventory = (app.devices() orelse return null).inventory() };
    }

    fn run(self: *App) i32 {
        const args = zSlice(self.sys.argsRaw());
        const profile = parseProfile(args);
        if (profile == .export_report) return self.exportReport();

        var buffer: [report_capacity]u8 = undefined;
        var writer = Writer.init(buffer[0..]);
        const ok = self.buildReport(&writer, profile);
        self.sys.write(writer.bytes());
        self.sys.write("HWDIAG result: ");
        self.sys.println(if (ok and !writer.truncated) "OK" else "FAILED");
        return if (ok and !writer.truncated) 0 else 1;
    }

    fn exportReport(self: *App) i32 {
        var buffer: [report_capacity]u8 = undefined;
        var writer = Writer.init(buffer[0..]);
        const ok_report = self.buildReport(&writer, .std);
        const data = writer.bytes();
        _ = self.sys.fileDelete(export_path);
        const written = self.sys.fileWrite(export_path, data);

        var verify: [report_capacity]u8 = undefined;
        const read = self.sys.fileRead(export_path, verify[0..]);
        const ok = ok_report and !writer.truncated and written == @as(i32, @intCast(data.len)) and
            read == @as(i32, @intCast(data.len)) and startsWith(verify[0..@intCast(read)], "HWDIAG.R4X");

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

        const hw = self.inventory.hardware() orelse {
            writer.line("Hardware-Summary: not available");
            return false;
        };
        writeHardwareSummary(writer, hw);

        const inv = self.inventory.summary() orelse {
            writer.line("");
            writer.line("Device inventory: not available");
            return false;
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
        writer.line("Cross references: DMESG for boot/error log, BOOTINFO.R4X for loader map, MEMVIEW.R4X for memory, DEVMGR.R4X for device details.");
        return true;
    }
};

pub fn r4_app_main(raw_app: *r4os.App) i32 {
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
    const inv = app.inventory.summary() orelse {
        writer.line("  not available");
        return;
    };

    var count: u32 = 0;
    var index: u32 = 0;
    while (index < inv.total) : (index += 1) {
        const rec = app.inventory.record(index) orelse continue;
        if (!matchesFilter(rec, filter)) continue;
        writeRecord(writer, index, rec);
        count += 1;
    }
    if (count == 0) writer.line("  none");
}

fn writeRecords(app: *App, writer: *Writer, total: u32, limit: u32, all: bool) void {
    const max = if (all or limit == 0 or total <= limit) total else limit;
    var index: u32 = 0;
    while (index < max) : (index += 1) {
        const rec = app.inventory.record(index) orelse continue;
        writeRecord(writer, index, rec);
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

fn parseProfile(args: []const u8) Profile {
    if (containsIgnoreCase(args, "EXPORT") or containsIgnoreCase(args, "/EXPORT")) return .export_report;
    if (containsIgnoreCase(args, "FULL") or containsIgnoreCase(args, "/FULL")) return .full;
    if (containsIgnoreCase(args, "MIN") or containsIgnoreCase(args, "/MIN")) return .min;
    return .std;
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

fn zSlice(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

fn startsWith(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    var i: usize = 0;
    while (i < prefix.len) : (i += 1) {
        if (value[i] != prefix[i]) return false;
    }
    return true;
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
