namespace Bolt.Protocol;

public readonly record struct DfuProgress(int PacketIndex, int PacketCount);

public sealed record DfuStatus(bool Success, bool Retryable, string Description);

public static class DfuFlasher
{
    private static readonly IReadOnlyDictionary<byte, DfuStatus> Statuses =
        new Dictionary<byte, DfuStatus>
        {
            [0x00] = new(false, false, "invalid"),
            [0x01] = new(true, false, "packet success"),
            [0x02] = new(true, false, "DFU success"),
            [0x03] = new(false, true, "wait for event"),
            [0x04] = new(false, false, "generic error 04"),
            [0x05] = new(true, false, "DFU success, entity restart required"),
            [0x06] = new(true, false, "DFU success, system restart required"),
            [0x10] = new(false, false, "generic error 10"),
            [0x11] = new(false, false, "bad voltage"),
            [0x12] = new(false, false, "unknown status 0x12"),
            [0x13] = new(false, false, "unsupported encryption mode"),
            [0x14] = new(false, false, "bad magic string"),
            [0x15] = new(false, false, "erase failure"),
            [0x16] = new(false, false, "DFU not started"),
            [0x17] = new(false, false, "bad sequence number"),
            [0x18] = new(false, false, "unsupported command"),
            [0x19] = new(false, true, "command in progress"),
            [0x1A] = new(false, false, "address out of range"),
            [0x1B] = new(false, false, "unaligned address"),
            [0x1C] = new(false, false, "bad size"),
            [0x1D] = new(false, false, "missing program data"),
            [0x1E] = new(false, false, "missing check data"),
            [0x1F] = new(false, false, "program failed to write"),
            [0x20] = new(false, false, "program failed to verify"),
            [0x21] = new(false, false, "bad firmware"),
            [0x22] = new(false, false, "firmware check failure"),
            [0x23] = new(false, true, "blocked command")
        };

    public static DfuStatus DescribeStatus(byte value)
    {
        var masked = (byte)(value & 0x7F);
        return Statuses.TryGetValue(masked, out var status)
            ? status
            : new(false, false, $"unhandled status 0x{masked:X2}");
    }

    public static async Task FlashPackageAsync(
        Hidpp20Session session,
        IHidppTransport transport,
        IReadOnlyList<ValidatedFirmwareImage> images,
        IProgress<DfuProgress>? progress,
        Action<string>? log,
        CancellationToken cancellationToken = default)
    {
        ValidateImages(images);
        var feature = await session.GetFeatureIndexAsync(
            HidppFeatures.Dfu, cancellationToken);
        if (feature == 0)
        {
            throw new NotSupportedException(
                "Device is not in bootloader mode: HID++ feature 0x00D0 is absent.");
        }

        const int chunkSize = 16;
        var packetCount = images.Sum(image =>
            (image.Data.Length + chunkSize - 1) / chunkSize);
        var completed = 0;

        foreach (var image in images)
        {
            var bytes = image.Data;
            log?.Invoke(
                $"Writing DFU entity 0x{bytes.Span[0]:X2} ({bytes.Length} bytes).");
            byte command = 0x04;
            for (var offset = 0; offset < bytes.Length; offset += chunkSize)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var length = Math.Min(chunkSize, bytes.Length - offset);
                var request = session.LongMessage(
                    feature, command, bytes.Slice(offset, length));
                var response = await transport.TransferAsync(
                    request, 2, cancellationToken: cancellationToken);
                await AcceptStatusAsync(
                    response, request, transport, log, cancellationToken);
                command = (byte)((command + 1) % 4);
                progress?.Report(new(++completed, packetCount));
            }
        }

        log?.Invoke("Both entities transferred; activating the application.");
        var restart = session.LongMessage(feature, 0x05, new byte[] { 0x02 });
        try
        {
            await transport.SendAsync(restart, 2, cancellationToken);
        }
        catch (Exception error) when (
            error is IOException or OperationCanceledException or ObjectDisposedException)
        {
            log?.Invoke($"USB-Endpunkt verschwand beim Neustart: {error.Message}");
        }
    }

    private static void ValidateImages(IReadOnlyList<ValidatedFirmwareImage> images)
    {
        if (images.Count != 2 ||
            images.Any(image => image.Data.IsEmpty) ||
            images.Select(image => image.Data.Span[0]).ToHashSet()
                .SetEquals(new byte[] { 0x01, 0x02 }) is false)
        {
            throw new HidppProtocolException(
                "A Bolt update requires DFU entity IDs 0x01 and 0x02.");
        }
    }

    private static async Task AcceptStatusAsync(
        HidppMessage initialResponse,
        HidppMessage request,
        IHidppTransport transport,
        Action<string>? log,
        CancellationToken cancellationToken)
    {
        var response = initialResponse;
        for (var attempt = 0; attempt <= 10; attempt++)
        {
            var data = response.Data.Span;
            var packet = data.Length >= 4
                ? ((uint)data[0] << 24) | ((uint)data[1] << 16) |
                  ((uint)data[2] << 8) | data[3]
                : 0;
            var value = data.Length > 4 ? data[4] : (byte)0;
            var status = DescribeStatus(value);
            if (status.Success)
            {
                return;
            }

            if (!status.Retryable || attempt == 10)
            {
                throw new IOException(
                    $"DFU packet {packet} failed: {status.Description} (0x{value:X2}).");
            }

            log?.Invoke(
                $"DFU packet {packet}: {status.Description}; waiting for completion event.");
            while (true)
            {
                var candidate = await transport.ReceiveAsync(
                    TimeSpan.FromSeconds(15), cancellationToken);
                if (IsReply(request, candidate, ignoreFunctionId: true))
                {
                    response = candidate;
                    break;
                }
            }
        }
    }

    private static bool IsReply(
        HidppMessage request,
        HidppMessage response,
        bool ignoreFunctionId)
    {
        var matchingDevice =
            request.DeviceId == response.DeviceId ||
            request.DeviceId == 0 ||
            response.DeviceId == 0;
        return matchingDevice &&
               request.SubId == response.SubId &&
               (ignoreFunctionId || request.FunctionId == response.FunctionId);
    }
}
