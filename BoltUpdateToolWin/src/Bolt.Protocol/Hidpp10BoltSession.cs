namespace Bolt.Protocol;

public sealed class Hidpp10BoltSession(IHidppTransport transport)
{
    private const byte SetLongRegister = 0x82;
    private const byte GetLongRegister = 0x83;
    private const byte PairingInformation = 0xB5;
    private const byte ReceiverFirmwareInformation = 0xF4;
    private const byte DfuControl = 0xF5;

    public async Task<byte> PingAsync(CancellationToken cancellationToken = default)
    {
        var request = new HidppMessage(
            HidppReportId.Short,
            HidppMessage.ReceiverDeviceId,
            0x00,
            0x10,
            new byte[] { 0x00, 0x00, 0xAA });

        try
        {
            var response = await transport.TransferAsync(
                request, 2, ignoreFunctionId: true, cancellationToken);
            return response.Data.Span[0];
        }
        catch (HidppRemoteException error) when (error.IsHidpp10 && error.Code == 0x01)
        {
            return 1;
        }
    }

    public async Task PrepareAsync(CancellationToken cancellationToken = default)
    {
        var request = new HidppMessage(
            HidppReportId.Short,
            HidppMessage.ReceiverDeviceId,
            GetLongRegister,
            PairingInformation,
            new byte[] { 0x02 });
        _ = await transport.TransferAsync(request, 1, cancellationToken: cancellationToken);
    }

    public async Task<IReadOnlyList<FirmwareEntity>> GetFirmwareEntitiesAsync(
        CancellationToken cancellationToken = default)
    {
        var entities = new List<FirmwareEntity>();
        for (var index = 0; index < 3; index++)
        {
            var request = new HidppMessage(
                HidppReportId.Short,
                HidppMessage.ReceiverDeviceId,
                GetLongRegister,
                ReceiverFirmwareInformation,
                new byte[] { (byte)index });
            var response = await transport.TransferAsync(
                request, 1, cancellationToken: cancellationToken);
            var data = response.Data.Span;
            if (data.Length < 5)
            {
                throw new HidppProtocolException("Short C548 firmware-information response.");
            }

            if (data[0] > 2)
            {
                continue;
            }

            entities.Add(new(
                index,
                data[0],
                data[0] switch { 0 => "MPR", 1 => "BOT", _ => "HW" },
                data[1],
                data[2],
                (ushort)((data[3] << 8) | data[4]),
                true));
        }

        return entities;
    }

    public Task ArmBootloaderAsync(CancellationToken cancellationToken = default)
    {
        var request = new HidppMessage(
            HidppReportId.Long,
            HidppMessage.ReceiverDeviceId,
            SetLongRegister,
            DfuControl,
            new byte[] { 0x01, 0x00, 0x00, 0x00, (byte)'P', (byte)'R', (byte)'E' });
        return transport.SendAsync(request, 1, cancellationToken);
    }
}
