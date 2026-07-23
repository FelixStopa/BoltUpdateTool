namespace Bolt.Protocol;

public sealed record FirmwareEntity(
    int Index,
    byte Kind,
    string Name,
    byte Major,
    byte Minor,
    ushort Build,
    bool Active)
{
    public string KindDescription => Kind switch
    {
        0 => "application",
        1 => "bootloader",
        2 => "hardware",
        _ => $"kind {Kind}"
    };

    public string Version => $"{Name}{Major:x2}.{Minor:x2}_B{Build:x4}";
}
