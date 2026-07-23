using System.Text;

namespace Bolt.Protocol;

public enum FirmwareImageKind
{
    Application,
    Secondary
}

public sealed record ValidatedFirmwareImage(
    FirmwareImageKind Kind,
    string FileName,
    ReadOnlyMemory<byte> Data);

public static class FirmwarePackageValidator
{
    private static readonly byte[] Identifier = Encoding.ASCII.GetBytes("MPR05_D0");

    public static IReadOnlyList<ValidatedFirmwareImage> Validate(
        IReadOnlyList<(string FileName, ReadOnlyMemory<byte> Data)> files)
    {
        if (files.Count != 2)
        {
            throw new HidppProtocolException("Exactly two unpacked .dfu files are required.");
        }

        var results = new List<ValidatedFirmwareImage>(2);
        foreach (var file in files)
        {
            if (!file.FileName.EndsWith(".dfu", StringComparison.OrdinalIgnoreCase) ||
                file.Data.Length is < 16 or > 16 * 1024 * 1024)
            {
                throw new HidppProtocolException($"{file.FileName} is not a valid unpacked DFU file.");
            }

            var bytes = file.Data.Span;
            if (!bytes.Slice(2, Identifier.Length).SequenceEqual(Identifier))
            {
                throw new HidppProtocolException(
                    $"{file.FileName} is not a Bolt C548 MPR05_D0 image.");
            }

            var kind = (bytes[0], bytes[1]) switch
            {
                (0x02, 0x01) => FirmwareImageKind.Application,
                (0x01, 0x03) => FirmwareImageKind.Secondary,
                _ => throw new HidppProtocolException(
                    $"{file.FileName} has unsupported entity bytes 0x{bytes[0]:X2} 0x{bytes[1]:X2}.")
            };
            results.Add(new(kind, file.FileName, file.Data));
        }

        if (results.Select(result => result.Kind).Distinct().Count() != 2)
        {
            throw new HidppProtocolException(
                "Select one application and one radio/secondary image.");
        }

        return results;
    }
}
