using Bolt.Protocol;

namespace Bolt.WindowsHid;

public enum FirmwareUpdateStage
{
    Preparing,
    SwitchingToBootloader,
    WaitingForReconnect,
    Flashing,
    Restarting,
    Verifying,
    Completed
}

public sealed record FirmwareUpdateResult(IReadOnlyList<FirmwareEntity> Entities);

public static class BoltFirmwareUpdater
{
    public static async Task<FirmwareUpdateResult> UpdateAsync(
        IReadOnlyList<ValidatedFirmwareImage> images,
        IProgress<DfuProgress>? progress,
        Action<FirmwareUpdateStage, string>? stageChanged,
        Action<string>? log,
        CancellationToken cancellationToken = default)
    {
        if (images.Count != 2)
        {
            throw new HidppProtocolException("Exactly two validated DFU images are required.");
        }

        stageChanged?.Invoke(
            FirmwareUpdateStage.Preparing,
            "Preparing the firmware package and receiver.");

        if (BoltDeviceLocator.ListBootloaderInterfaces().Count == 0)
        {
            stageChanged?.Invoke(
                FirmwareUpdateStage.SwitchingToBootloader,
                "Preparing C548 for the signed Bolt bootloader.");
            var runtime = BoltDeviceLocator.FindRuntimeHidppInterfaces();
            await using (var transport = WindowsHidppTransport.OpenRuntimeForFirmwareUpdate(
                             runtime.ShortReports, runtime.LongReports))
            {
                var session = new Hidpp10BoltSession(transport);
                await session.PrepareAsync(cancellationToken);
                log?.Invoke(
                    "Sending signed F5 DFU-control command with PRE identifier.");
                try
                {
                    await session.ArmBootloaderAsync(cancellationToken);
                }
                catch (Exception error) when (
                    error is IOException ||
                    error is OperationCanceledException &&
                    !cancellationToken.IsCancellationRequested)
                {
                    log?.Invoke(
                        $"The runtime endpoint stopped responding during bootloader transition: " +
                        error.Message);
                }
            }

            if (!await WaitForProductAsync(
                    BoltDeviceLocator.BootloaderProductId,
                    TimeSpan.FromSeconds(5),
                    cancellationToken))
            {
                stageChanged?.Invoke(
                    FirmwareUpdateStage.WaitingForReconnect,
                    "Unplug and reconnect the receiver now. Waiting for AB07.");
                if (!await WaitForProductAsync(
                        BoltDeviceLocator.BootloaderProductId,
                        TimeSpan.FromMinutes(3),
                        cancellationToken))
                {
                    throw new TimeoutException(
                        "AB07 was not detected within three minutes after reconnecting.");
                }
            }
        }
        else
        {
            log?.Invoke("The receiver is already in the AB07 bootloader.");
        }

        stageChanged?.Invoke(
            FirmwareUpdateStage.Flashing,
            "Writing both firmware entities. Do not unplug the receiver.");
        var bootloaderInterfaces = BoltDeviceLocator.FindBootloaderHidppInterfaces();
        await using (var bootloader = WindowsHidppTransport.OpenBootloader(
                         bootloaderInterfaces.ShortReports,
                         bootloaderInterfaces.LongReports))
        {
            var session = new Hidpp20Session(bootloader);
            var version = await session.PingAsync(cancellationToken);
            if (version < 2)
            {
                throw new NotSupportedException(
                    $"AB07 negotiated HID++ {version}.0 instead of HID++ 2.0.");
            }

            log?.Invoke($"AB07 responded using HID++ {version}.0.");
            await DfuFlasher.FlashPackageAsync(
                session,
                bootloader,
                images,
                progress,
                log,
                cancellationToken);
        }

        stageChanged?.Invoke(
            FirmwareUpdateStage.Restarting,
            "Transfer complete; the receiver is restarting.");
        if (!await WaitForProductAsync(
                BoltDeviceLocator.RuntimeProductId,
                TimeSpan.FromSeconds(45),
                cancellationToken))
        {
            throw new TimeoutException(
                "C548 did not return after the firmware restart.");
        }

        stageChanged?.Invoke(
            FirmwareUpdateStage.Verifying,
            "Verifying firmware versions after restart.");
        IReadOnlyList<FirmwareEntity>? entities = null;
        Exception? lastError = null;
        for (var attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                var runtime = BoltDeviceLocator.FindRuntimeHidppInterfaces();
                await using var transport = WindowsHidppTransport.OpenRuntime(
                    runtime.ShortReports, runtime.LongReports);
                var session = new Hidpp10BoltSession(transport);
                await session.PrepareAsync(cancellationToken);
                entities = await session.GetFirmwareEntitiesAsync(cancellationToken);
                break;
            }
            catch (Exception error)
            {
                lastError = error;
                await Task.Delay(500, cancellationToken);
            }
        }

        if (entities is null)
        {
            throw lastError ?? new IOException(
                "C548 returned, but its firmware information could not be read.");
        }

        stageChanged?.Invoke(
            FirmwareUpdateStage.Completed,
            "Firmware update complete; C548 was verified successfully.");
        return new(entities);
    }

    private static async Task<bool> WaitForProductAsync(
        ushort productId,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            var present = productId == BoltDeviceLocator.RuntimeProductId
                ? BoltDeviceLocator.ListRuntimeInterfaces().Count > 0
                : BoltDeviceLocator.ListBootloaderInterfaces().Count > 0;
            if (present)
            {
                return true;
            }

            await Task.Delay(500, cancellationToken);
        }

        return false;
    }
}
