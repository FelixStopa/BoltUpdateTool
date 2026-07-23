using Bolt.Protocol;
using Bolt.WindowsHid;

return args.Contains("--device", StringComparer.OrdinalIgnoreCase)
    ? await RunDeviceDiagnosticsAsync()
    : await RunProtocolTestsAsync();

static async Task<int> RunProtocolTestsAsync()
{
    var failures = new List<string>();
    Check(
        "short report packing",
        new HidppMessage(
            HidppReportId.Short, 0xFF, 0x83, 0xF4, new byte[] { 2 }).Pack()
            .SequenceEqual(new byte[] { 0x10, 0xFF, 0x83, 0xF4, 2, 0, 0 }),
        failures);

    var application = MakeImage(0x02, 0x01);
    var secondary = MakeImage(0x01, 0x03);
    var package = FirmwarePackageValidator.Validate(
        new[]
        {
            ("receiver_app.dfu", (ReadOnlyMemory<byte>)application),
            ("receiver_secondary.dfu", (ReadOnlyMemory<byte>)secondary)
        });
    Check(
        "entity-based package classification",
        package[0].Kind == FirmwareImageKind.Application &&
        package[1].Kind == FirmwareImageKind.Secondary,
        failures);

    var rejected = false;
    try
    {
        var wrong = MakeImage(0x02, 0x01);
        wrong[2] = (byte)'X';
        _ = FirmwarePackageValidator.Validate(
            new[]
            {
                ("one.dfu", (ReadOnlyMemory<byte>)wrong),
                ("two.dfu", (ReadOnlyMemory<byte>)secondary)
            });
    }
    catch (HidppProtocolException)
    {
        rejected = true;
    }

    Check("MPR05_D0 enforcement", rejected, failures);

    Check(
        "retryable DFU status",
        DfuFlasher.DescribeStatus(0x19).Retryable &&
        !DfuFlasher.DescribeStatus(0x19).Success,
        failures);
    Check(
        "successful DFU status",
        DfuFlasher.DescribeStatus(0x01).Success,
        failures);

    var fake = new FakeTransport();
    fake.Responses.Enqueue(new HidppMessage(
        HidppReportId.Short, 0xFF, 0x00, 0x00, new byte[] { 0x07, 0, 0 }));
    fake.Responses.Enqueue(SuccessfulDfuResponse(1));
    fake.Responses.Enqueue(SuccessfulDfuResponse(2));
    await using (fake)
    {
        var session = new Hidpp20Session(fake);
        await DfuFlasher.FlashPackageAsync(
            session,
            fake,
            new[]
            {
                new ValidatedFirmwareImage(
                    FirmwareImageKind.Application, "app.dfu", application),
                new ValidatedFirmwareImage(
                    FirmwareImageKind.Secondary, "secondary.dfu", secondary)
            },
            null,
            null);
    }

    Check(
        "DFU feature 0x00D0 lookup",
        fake.Transfers[0].Data.Span[..2].SequenceEqual(new byte[] { 0x00, 0xD0 }),
        failures);
    Check(
        "both DFU entities transferred",
        fake.Transfers.Count(message => message.ReportId == HidppReportId.Long) == 2,
        failures);
    Check(
        "application activation sent",
        fake.Sends.Count == 1 &&
        fake.Sends[0].FunctionId == 0x50 &&
        fake.Sends[0].Data.Span[0] == 0x02,
        failures);

    Console.WriteLine(failures.Count == 0
        ? "All protocol tests passed."
        : string.Join(Environment.NewLine, failures));
    return failures.Count == 0 ? 0 : 1;
}

static HidppMessage SuccessfulDfuResponse(uint packet) =>
    new(
        HidppReportId.Long,
        0xFF,
        0x07,
        0x40,
        new byte[]
        {
            (byte)(packet >> 24),
            (byte)(packet >> 16),
            (byte)(packet >> 8),
            (byte)packet,
            0x01
        });

static async Task<int> RunDeviceDiagnosticsAsync()
{
    Console.WriteLine("Phase 4: all HID interfaces for 046D:C548");
    var devices = BoltDeviceLocator.ListRuntimeInterfaces();
    if (devices.Count == 0)
    {
        Console.WriteLine("No interfaces for 046D:C548 found.");
        return 2;
    }

    foreach (var device in devices)
    {
        Console.WriteLine(
            $"VID:PID={device.VendorId:X4}:{device.ProductId:X4} " +
            $"UsagePage=0x{device.UsagePage:X4} Usage=0x{device.Usage:X4} " +
            $"Input={device.InputReportLength} Output={device.OutputReportLength} " +
            $"Feature={device.FeatureReportLength}");
        Console.WriteLine($"Product={device.Product}");
        Console.WriteLine($"Path={device.DevicePath}");
    }

    try
    {
        var runtime = BoltDeviceLocator.FindRuntimeHidppInterfaces();
        Console.WriteLine(
            "Phase 5: opening FF00:0001 for short-report queries and " +
            "FF00:0002 read-only for long-report replies.");
        await using var transport = WindowsHidppTransport.OpenRuntime(
            runtime.ShortReports,
            runtime.LongReports);
        var session = new Hidpp10BoltSession(transport);
        var protocol = await session.PingAsync();
        Console.WriteLine($"Phase 6: HID++ ping reports protocol {protocol}.0.");
        await session.PrepareAsync();
        var entities = await session.GetFirmwareEntitiesAsync();
        foreach (var entity in entities)
        {
            Console.WriteLine(
                $"Entity {entity.Index}: {entity.KindDescription}, " +
                $"version={entity.Version}, active={entity.Active}");
        }

        return 0;
    }
    catch (Exception error)
    {
        Console.WriteLine($"Phase 5/6 failed: {error.Message}");
        return 3;
    }
}

static byte[] MakeImage(byte entity, byte marker)
{
    var bytes = new byte[16];
    bytes[0] = entity;
    bytes[1] = marker;
    "MPR05_D0"u8.CopyTo(bytes.AsSpan(2));
    return bytes;
}

static void Check(string name, bool condition, ICollection<string> failures)
{
    if (!condition)
    {
        failures.Add($"FAILED: {name}");
    }
}

sealed class FakeTransport : IHidppTransport
{
    public Queue<HidppMessage> Responses { get; } = [];
    public List<HidppMessage> Transfers { get; } = [];
    public List<HidppMessage> Sends { get; } = [];

    public Task SendAsync(
        HidppMessage message,
        int hidppVersion,
        CancellationToken cancellationToken = default)
    {
        Sends.Add(message);
        return Task.CompletedTask;
    }

    public Task<HidppMessage> ReceiveAsync(
        TimeSpan timeout,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(Responses.Dequeue());

    public Task<HidppMessage> TransferAsync(
        HidppMessage request,
        int hidppVersion,
        bool ignoreFunctionId = false,
        CancellationToken cancellationToken = default)
    {
        Transfers.Add(request);
        return Task.FromResult(Responses.Dequeue());
    }

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
