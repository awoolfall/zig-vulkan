const std = @import("std");
const eng = @import("self");
const zm = eng.zmath;

const Self = @This();

pub const default_palette = dark_primary(hsl("262.1 83.3% 57.8%") catch unreachable); // dark violet

background: zm.F32x4,
foreground: zm.F32x4,
primary: zm.F32x4,
secondary: zm.F32x4,
accent: zm.F32x4,
text_dark: zm.F32x4,
text_light: zm.F32x4,
border: zm.F32x4,
muted: zm.F32x4,

fn hsl(str: []const u8) !zm.F32x4 {
    var tokens = std.mem.tokenizeScalar(u8, str, ' ');

    const hue_str = tokens.next() orelse return error.InvalidString;
    const hue = (try std.fmt.parseFloat(f32, hue_str)) / 360.0;

    var sat_str = tokens.next() orelse return error.InvalidString;
    var sat_scale: f32 = 1.0;
    if (sat_str[sat_str.len - 1] == '%') {
        sat_str = sat_str[0..(sat_str.len-1)];
        sat_scale = 100.0;
    }
    const saturation = (try std.fmt.parseFloat(f32, sat_str)) / sat_scale;

    var val_str = tokens.next() orelse return error.InvalidString;
    var val_scale: f32 = 1.0;
    if (val_str[val_str.len - 1] == '%') {
        val_str = val_str[0..(val_str.len-1)];
        val_scale = 100.0;
    }
    const value = (try std.fmt.parseFloat(f32, val_str)) / val_scale;

    return zm.srgbToRgb(zm.hslToRgb(zm.f32x4(hue, saturation, value, 1.0)));
}

pub fn slate() Self {
    @setEvalBranchQuota(10000);
    return Self {
        .text_light = zm.srgbToRgb(zm.f32x4(248.0/255.0, 250.0/255.0, 252.0/255.0, 1.0)), 
        .text_dark = zm.srgbToRgb(zm.f32x4(15.0/255.0, 23.0/255.0, 42.0/255.0, 1.0)),
        .primary = hsl("222.2 47.4% 11.2%") catch unreachable,
        .border = hsl("214.3 31.8% 91.4%") catch unreachable,
        .background = hsl("0 0% 100%") catch unreachable,
        .foreground = hsl("222.2 84% 4.9%") catch unreachable,
        .muted = hsl("210 40% 96.1%") catch unreachable,
        .secondary = hsl("210 40% 96.1%") catch unreachable,
        .accent = hsl("210 40% 96.1%") catch unreachable,
    };
}

pub fn dark() Self {
    @setEvalBranchQuota(10000);
    return Self {
        .background = hsl("222 20% 12%") catch unreachable,
        .foreground = hsl("222 14% 18%") catch unreachable,
        .primary = hsl("214 90% 62%") catch unreachable,
        .secondary = hsl("215 18% 24%") catch unreachable,
        .accent = hsl("200 90% 55%") catch unreachable,
        .text_dark = zm.srgbToRgb(zm.f32x4(220.0/255.0, 225.0/255.0, 230.0/255.0, 1.0)),
        .text_light = zm.srgbToRgb(zm.f32x4(250.0/255.0, 251.0/255.0, 252.0/255.0, 1.0)),
        .border = hsl("215 10% 28%") catch unreachable,
        .muted = hsl("220 10% 20%") catch unreachable,
    };
}


//      :root {
//    --radius: 0.65rem;
//    --background:  hsl(0 0% 100%);
//    --foreground:  hsl(224 71.4% 4.1%);
//    --card:  hsl(0 0% 100%);
//    --card-foreground:  hsl(224 71.4% 4.1%);
//    --popover:  hsl(0 0% 100%);
//    --popover-foreground:  hsl(224 71.4% 4.1%);
//    --primary:  hsl(262.1 83.3% 57.8%);
//    --primary-foreground:  hsl(210 20% 98%);
//    --secondary:  hsl(220 14.3% 95.9%);
//    --secondary-foreground:  hsl(220.9 39.3% 11%);
//    --muted:  hsl(220 14.3% 95.9%);
//    --muted-foreground:  hsl(220 8.9% 46.1%);
//    --accent:  hsl(220 14.3% 95.9%);
//    --accent-foreground:  hsl(220.9 39.3% 11%);
//    --destructive:  hsl(0 84.2% 60.2%);
//    --destructive-foreground:  hsl(210 20% 98%);
//    --border:  hsl(220 13% 91%);
//    --input:  hsl(220 13% 91%);
//    --ring:  hsl(262.1 83.3% 57.8%);
//    --chart-1:  hsl(12 76% 61%);
//    --chart-2:  hsl(173 58% 39%);
//    --chart-3:  hsl(197 37% 24%);
//    --chart-4:  hsl(43 74% 66%);
//    --chart-5:  hsl(27 87% 67%);
//  }
//  .dark {
//    --background:  hsl(224 71.4% 4.1%);
//    --foreground:  hsl(210 20% 98%);
//    --card:  hsl(224 71.4% 4.1%);
//    --card-foreground:  hsl(210 20% 98%);
//    --popover:  hsl(224 71.4% 4.1%);
//    --popover-foreground:  hsl(210 20% 98%);
//    --primary:  hsl(263.4 70% 50.4%);
//    --primary-foreground:  hsl(210 20% 98%);
//    --secondary:  hsl(215 27.9% 16.9%);
//    --secondary-foreground:  hsl(210 20% 98%);
//    --muted:  hsl(215 27.9% 16.9%);
//    --muted-foreground:  hsl(217.9 10.6% 64.9%);
//    --accent:  hsl(215 27.9% 16.9%);
//    --accent-foreground:  hsl(210 20% 98%);
//    --destructive:  hsl(0 62.8% 30.6%);
//    --destructive-foreground:  hsl(210 20% 98%);
//    --border:  hsl(215 27.9% 16.9%);
//    --input:  hsl(215 27.9% 16.9%);
//    --ring:  hsl(263.4 70% 50.4%);
//    --chart-1:  hsl(220 70% 50%);
//    --chart-2:  hsl(160 60% 45%);
//    --chart-3:  hsl(30 80% 55%);
//    --chart-4:  hsl(280 65% 60%);
//    --chart-5:  hsl(340 75% 55%);
//  }

pub fn light_primary(primary_colour: zm.F32x4) Self {
    @setEvalBranchQuota(10000);
    return Self {
        .background = hsl("0 0% 100%") catch unreachable,
        .foreground = hsl("224 71.4% 4.1%") catch unreachable,
        .primary = primary_colour,
        .secondary = hsl("220 14.3% 95.9%") catch unreachable,
        .accent = hsl("220 14.3% 95.9%") catch unreachable,
        .text_dark = hsl("224 71.4% 4.1%") catch unreachable,
        .text_light = hsl("210 20% 98%") catch unreachable,
        .border = hsl("220 13% 91%") catch unreachable,
        .muted = hsl("220 14.3% 95.9%") catch unreachable,
    };
}

pub fn dark_primary(primary_colour: zm.F32x4) Self {
    @setEvalBranchQuota(10000);
    return Self {
        .background = hsl("224 71.4% 4.1%") catch unreachable,
        .foreground = hsl("210 20% 98%") catch unreachable,
        .primary = primary_colour,
        .secondary = hsl("215 27.9% 16.9%") catch unreachable,
        .accent = hsl("215 27.9% 16.9%") catch unreachable, // TODO: add destructive, input, ring colors
        .text_dark = hsl("224 71.4% 4.1%") catch unreachable,
        .text_light = hsl("210 20% 98%") catch unreachable,
        .border = hsl("215 27.9% 16.9%") catch unreachable,
        .muted = hsl("215 27.9% 16.9%") catch unreachable,
    };
}
