//! Represents a defined symbol.

/// Allocated address value of this symbol.
value: u64 = 0,

/// Offset into the linker's string table.
name_offset: u32 = 0,

/// Index of file where this symbol is defined.
file_index: File.Index = 0,

/// Index of atom containing this symbol.
/// Index of 0 means there is no associated atom with this symbol.
/// Use `atom` to get the pointer to the atom.
atom_index: Atom.Index = 0,

/// Assigned output section index for this atom.
output_section_index: u16 = 0,

/// Index of the source symbol this symbol references.
/// Use `getSourceSymbol` to pull the source symbol from the relevant file.
symbol_index: Index = 0,

/// Index of the source version symbol this symbol references if any.
/// If the symbol is unversioned it will have either VER_NDX_LOCAL or VER_NDX_GLOBAL.
version_index: elf.Elf64_Versym = elf.VER_NDX_LOCAL,

/// Misc flags for the symbol packaged as packed struct for compression.
flags: Flags = .{},

extra_index: u32 = 0,

pub fn isAbs(symbol: Symbol, elf_file: *Elf) bool {
    const file_ptr = symbol.file(elf_file).?;
    if (file_ptr == .shared) return symbol.sourceSymbol(elf_file).st_shndx == elf.SHN_ABS;
    return !symbol.flags.import and symbol.atom(elf_file) == null and symbol.shndx == 0 
        and file_ptr != .linker_defined and file_ptr != .zig_module;
}

pub fn isLocal(symbol: Symbol) bool {
    return !(symbol.flags.import or symbol.flags.@"export");
}

pub inline fn isIFunc(symbol: Symbol, elf_file: *Elf) bool {
    return symbol.@"type"(elf_file) == elf.STT_GNU_IFUNC;
}

pub fn @"type"(symbol: Symbol, elf_file: *Elf) u4 {
    const file_ptr = symbol.file(elf_file).?;
    const s_sym = symbol.sourceSymbol(elf_file);
    if (s_sym.st_type() == elf.STT_GNU_IFUNC and file_ptr == .shared) return elf.STT_FUNC;
    return s_sym.st_type();
}

pub fn name(symbol: Symbol, elf_file: *Elf) [:0]const u8 {
    return elf_file.strtab.getAssumeExists(symbol.name);
}

pub fn atom(symbol: Symbol, elf_file: *Elf) ?*Atom {
    return elf_file.atom(symbol.atom);
}

pub fn file(symbol: Symbol, elf_file: *Elf) ?File {
    return elf_file.file(symbol.file);
}

pub fn sourceSymbol(symbol: Symbol, elf_file: *Elf) elf.Elf64_Sym {
    const file_ptr = symbol.file(elf_file).?;
    return switch (file_ptr) {
        .linker_defined, .zig_module => |x| x.symtab.items[symbol.sym_idx],
        inline else => |x| x.symtab[symbol.sym_idx],
    };
}

pub fn symbolRank(symbol: Symbol, elf_file: *Elf) u32 {
    const file_ptr = symbol.file(elf_file) orelse return std.math.maxInt(u32);
    const sym = symbol.sourceSymbol(elf_file);
    const in_archive = switch (file) {
        // .object => |x| !x.alive,
        else => false,
    };
    return file_ptr.symbolRank(sym, in_archive);
}

pub fn address(symbol: Symbol, opts: struct {
    plt: bool = true,
}, elf_file: *Elf) u64 {
    // if (symbol.flags.copy_rel) {
    //     return elf_file.sectionAddress(elf_file.copy_rel_sect_index.?) + symbol.value;
    // }
    // if (symbol.flags.plt and opts.plt) {
    //     const extra = symbol.getExtra(elf_file).?;
    //     if (!symbol.flags.is_canonical and symbol.flags.got) {
    //         // We have a non-lazy bound function pointer, use that!
    //         return elf_file.getPltGotEntryAddress(extra.plt_got);
    //     }
    //     // Lazy-bound function it is!
    //     return elf_file.getPltEntryAddress(extra.plt);
    // }
    return symbol.value;
}

pub fn gotAddress(symbol: Symbol, elf_file: *Elf) u64 {
    if (!symbol.flags.got) return 0;
    const extra = symbol.extra(elf_file).?;
    return elf_file.gotEntryAddress(extra.got);
}

// pub fn tlsGdAddress(symbol: Symbol, elf_file: *Elf) u64 {
//     if (!symbol.flags.tlsgd) return 0;
//     const extra = symbol.getExtra(elf_file).?;
//     return elf_file.getGotEntryAddress(extra.tlsgd);
// }

// pub fn gotTpAddress(symbol: Symbol, elf_file: *Elf) u64 {
//     if (!symbol.flags.gottp) return 0;
//     const extra = symbol.getExtra(elf_file).?;
//     return elf_file.getGotEntryAddress(extra.gottp);
// }

// pub fn tlsDescAddress(symbol: Symbol, elf_file: *Elf) u64 {
//     if (!symbol.flags.tlsdesc) return 0;
//     const extra = symbol.getExtra(elf_file).?;
//     return elf_file.getGotEntryAddress(extra.tlsdesc);
// }

// pub fn alignment(symbol: Symbol, elf_file: *Elf) !u64 {
//     const file = symbol.getFile(elf_file) orelse return 0;
//     const shared = file.shared;
//     const s_sym = symbol.getSourceSymbol(elf_file);
//     const shdr = shared.getShdrs()[s_sym.st_shndx];
//     const alignment = @max(1, shdr.sh_addralign);
//     return if (s_sym.st_value == 0)
//         alignment
//     else
//         @min(alignment, try std.math.powi(u64, 2, @ctz(s_sym.st_value)));
// }

pub fn addExtra(symbol: *Symbol, extra: Extra, elf_file: *Elf) !void {
    symbol.extra = try elf_file.addSymbolExtra(extra);
}

pub fn extra(symbol: Symbol, elf_file: *Elf) ?Extra {
    return elf_file.symbolExtra(symbol.extra);
}

pub fn setExtra(symbol: Symbol, extra: Extra, elf_file: *Elf) void {
    elf_file.setSymbolExtra(symbol.extra, extra);
}

pub fn asElfSym(symbol: Symbol, st_name: u32, elf_file: *Elf) elf.Elf64_Sym {
    const file_ptr = symbol.file(elf_file).?;
    const s_sym = symbol.sourceSymbol(elf_file);
    const st_type = symbol.@"type"(elf_file);
    const st_bind: u8 = blk: {
        if (symbol.isLocal()) break :blk 0;
        if (symbol.flags.weak) break :blk elf.STB_WEAK;
        // if (file_ptr == .shared) break :blk elf.STB_GLOBAL;
        break :blk s_sym.st_bind();
    };
    const st_shndx = blk: {
        // if (symbol.flags.copy_rel) break :blk elf_file.copy_rel_sect_index.?;
        // if (file_ptr == .shared or s_sym.st_shndx == elf.SHN_UNDEF) break :blk elf.SHN_UNDEF;
        if (symbol.atom(elf_file) == null and file_ptr != .linker_defined and file_ptr != .zig_module) 
            break :blk elf.SHN_ABS;
        break :blk symbol.shndx;
    };
    const st_value = blk: {
        // if (symbol.flags.copy_rel) break :blk symbol.address(.{}, elf_file);
        // if (file_ptr == .shared or s_sym.st_shndx == elf.SHN_UNDEF) {
        //     if (symbol.flags.is_canonical) break :blk symbol.address(.{}, elf_file);
        //     break :blk 0;
        // }
        // if (st_shndx == elf.SHN_ABS) break :blk symbol.value;
        // const shdr = &elf_file.sections.items(.shdr)[st_shndx];
        // if (Elf.shdrIsTls(shdr)) break :blk symbol.value - elf_file.getTlsAddress();
        break :blk symbol.value;
    };
    return elf.Elf64_Sym{
        .st_name = st_name,
        .st_info = (st_bind << 4) | st_type,
        .st_other = s_sym.st_other,
        .st_shndx = st_shndx,
        .st_value = st_value,
        .st_size = s_sym.st_size,
    };
}

pub fn format(
    symbol: Symbol,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = symbol;
    _ = unused_fmt_string;
    _ = options;
    _ = writer;
    @compileError("do not format symbols directly");
}

const FormatContext = struct {
    symbol: Symbol,
    elf_file: *Elf,
};

pub fn fmtName(symbol: Symbol, elf_file: *Elf) std.fmt.Formatter(formatName) {
    return .{ .data = .{
        .symbol = symbol,
        .elf_file = elf_file,
    } };
}

fn formatName(
    ctx: FormatContext,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    _ = unused_fmt_string;
    const elf_file = ctx.elf_file;
    const symbol = ctx.symbol;
    try writer.writeAll(symbol.getName(elf_file));
    switch (symbol.ver_idx & elf.VERSYM_VERSION) {
        elf.VER_NDX_LOCAL, elf.VER_NDX_GLOBAL => {},
        else => {
            unreachable;
            // const shared = symbol.getFile(elf_file).?.shared;
            // try writer.print("@{s}", .{shared.getVersionString(symbol.ver_idx)});
        },
    }
}

pub fn fmt(symbol: Symbol, elf_file: *Elf) std.fmt.Formatter(format2) {
    return .{ .data = .{
        .symbol = symbol,
        .elf_file = elf_file,
    } };
}

fn format2(
    ctx: FormatContext,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    _ = unused_fmt_string;
    const symbol = ctx.symbol;
    try writer.print("%{d} : {s} : @{x}", .{ symbol.sym_idx, symbol.fmtName(ctx.elf_file), symbol.value });
    if (symbol.getFile(ctx.elf_file)) |file| {
        if (symbol.isAbs(ctx.elf_file)) {
            if (symbol.getSourceSymbol(ctx.elf_file).st_shndx == elf.SHN_UNDEF) {
                try writer.writeAll(" : undef");
            } else {
                try writer.writeAll(" : absolute");
            }
        } else if (symbol.shndx != 0) {
            try writer.print(" : sect({d})", .{symbol.shndx});
        }
        if (symbol.getAtom(ctx.elf_file)) |atom| {
            try writer.print(" : atom({d})", .{atom.atom_index});
        }
        var buf: [2]u8 = .{'_'} ** 2;
        if (symbol.flags.@"export") buf[0] = 'E';
        if (symbol.flags.import) buf[1] = 'I';
        try writer.print(" : {s}", .{&buf});
        if (symbol.flags.weak) try writer.writeAll(" : weak");
        switch (file) {
            .internal => |x| try writer.print(" : internal({d})", .{x.index}),
            .object => |x| try writer.print(" : object({d})", .{x.index}),
            .shared => |x| try writer.print(" : shared({d})", .{x.index}),
        }
    } else try writer.writeAll(" : unresolved");
}

pub const Flags = packed struct {
    /// Whether the symbol is imported at runtime.
    import: bool = false,

    /// Whether the symbol is exported at runtime.
    @"export": bool = false,

    /// Whether this symbol is weak.
    weak: bool = false,

    /// Whether the symbol makes into the output symtab or not.
    output_symtab: bool = false,

    /// Whether the symbol contains GOT indirection.
    got: bool = false,

    /// Whether the symbol contains PLT indirection.
    plt: bool = false,
    /// Whether the PLT entry is canonical.
    is_canonical: bool = false,

    /// Whether the symbol contains COPYREL directive.
    copy_rel: bool = false,
    has_copy_rel: bool = false,
    has_dynamic: bool = false,

    /// Whether the symbol contains TLSGD indirection.
    tlsgd: bool = false,

    /// Whether the symbol contains GOTTP indirection.
    gottp: bool = false,

    /// Whether the symbol contains TLSDESC indirection.
    tlsdesc: bool = false,
};

pub const Extra = struct {
    got: u32 = 0,
    plt: u32 = 0,
    plt_got: u32 = 0,
    dynamic: u32 = 0,
    copy_rel: u32 = 0,
    tlsgd: u32 = 0,
    gottp: u32 = 0,
    tlsdesc: u32 = 0,
};

pub const Index = u32;

const std = @import("std");
const assert = std.debug.assert;
const elf = std.elf;

const Atom = @import("Atom.zig");
const Elf = @import("../Elf.zig");
const File = @import("file.zig").File;
const InternalObject = @import("InternalObject.zig");
const Object = @import("Object.zig");
const SharedObject = @import("SharedObject.zig");
const Symbol = @This();
