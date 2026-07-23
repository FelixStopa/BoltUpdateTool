using System.ComponentModel;
using Bolt.Protocol;
using Microsoft.Win32.SafeHandles;

namespace Bolt.WindowsHid;

public sealed class WindowsHidppTransport : IHidppTransport
{
    private readonly HidDeviceInfo shortReportDevice;
    private readonly HidDeviceInfo longReportDevice;
    private readonly SafeFileHandle shortReportHandle;
    private readonly SafeFileHandle longReportHandle;
    private readonly FileStream shortReportStream;
    private readonly FileStream longReportStream;

    private WindowsHidppTransport(
        HidDeviceInfo shortReportDevice,
        HidDeviceInfo longReportDevice,
        SafeFileHandle shortReportHandle,
        SafeFileHandle longReportHandle,
        FileStream shortReportStream,
        FileStream longReportStream)
    {
        this.shortReportDevice = shortReportDevice;
        this.longReportDevice = longReportDevice;
        this.shortReportHandle = shortReportHandle;
        this.longReportHandle = longReportHandle;
        this.shortReportStream = shortReportStream;
        this.longReportStream = longReportStream;
    }

    public static WindowsHidppTransport OpenRuntime(
        HidDeviceInfo shortReportDevice,
        HidDeviceInfo longReportDevice)
    {
        ValidateRuntimeInterfaces(shortReportDevice, longReportDevice);
        return Open(shortReportDevice, longReportDevice, longReportsWritable: false);
    }

    public static WindowsHidppTransport OpenRuntimeForFirmwareUpdate(
        HidDeviceInfo shortReportDevice,
        HidDeviceInfo longReportDevice)
    {
        ValidateRuntimeInterfaces(shortReportDevice, longReportDevice);
        return Open(shortReportDevice, longReportDevice, longReportsWritable: true);
    }

    public static WindowsHidppTransport OpenBootloader(
        HidDeviceInfo shortReportDevice,
        HidDeviceInfo longReportDevice)
    {
        if (shortReportDevice.ProductId != BoltDeviceLocator.BootloaderProductId ||
            longReportDevice.ProductId != BoltDeviceLocator.BootloaderProductId)
        {
            throw new InvalidOperationException("Refusing non-AB07 bootloader interfaces.");
        }

        return Open(shortReportDevice, longReportDevice, longReportsWritable: true);
    }

    private static void ValidateRuntimeInterfaces(
        HidDeviceInfo shortReportDevice,
        HidDeviceInfo longReportDevice)
    {
        if (!shortReportDevice.IsBoltRuntimeHidpp ||
            !longReportDevice.IsBoltRuntimeHidppLongReports)
        {
            throw new InvalidOperationException(
                "Refusing runtime interfaces other than C548 FF00:0001/0002.");
        }
    }

    private static WindowsHidppTransport Open(
        HidDeviceInfo shortReportDevice,
        HidDeviceInfo longReportDevice,
        bool longReportsWritable)
    {
        if (shortReportDevice.VendorId != BoltDeviceLocator.LogitechVendorId ||
            longReportDevice.VendorId != BoltDeviceLocator.LogitechVendorId ||
            shortReportDevice.ProductId != longReportDevice.ProductId ||
            shortReportDevice.ProductId is not (
                BoltDeviceLocator.RuntimeProductId or BoltDeviceLocator.BootloaderProductId))
        {
            throw new InvalidOperationException(
                "Refusing to open interfaces outside Bolt C548/AB07.");
        }

        var shortHandle = NativeMethods.CreateFile(
            shortReportDevice.DevicePath,
            NativeMethods.GenericRead | NativeMethods.GenericWrite,
            NativeMethods.FileShareRead | NativeMethods.FileShareWrite,
            0,
            NativeMethods.OpenExisting,
            NativeMethods.FileFlagOverlapped,
            0);
        if (shortHandle.IsInvalid)
        {
            var code = shortHandle.GetLastWin32Error();
            shortHandle.Dispose();
            throw new Win32Exception(
                code,
                "The Bolt HID++ interface could not be opened. Logi Options+ may be " +
                "holding the device; close it completely and try again.");
        }

        var longHandle = NativeMethods.CreateFile(
            longReportDevice.DevicePath,
            longReportsWritable
                ? NativeMethods.GenericRead | NativeMethods.GenericWrite
                : NativeMethods.GenericRead,
            NativeMethods.FileShareRead | NativeMethods.FileShareWrite,
            0,
            NativeMethods.OpenExisting,
            NativeMethods.FileFlagOverlapped,
            0);
        if (longHandle.IsInvalid)
        {
            var code = longHandle.GetLastWin32Error();
            longHandle.Dispose();
            shortHandle.Dispose();
            throw new Win32Exception(
                code,
                "The Bolt long-report interface could not be opened read-only. " +
                "Logi Options+ may be holding the device; close it completely and try again.");
        }

        try
        {
            var shortStream = new FileStream(
                shortHandle,
                FileAccess.ReadWrite,
                Math.Max(
                    shortReportDevice.InputReportLength,
                    shortReportDevice.OutputReportLength),
                isAsync: true);
            var longStream = new FileStream(
                longHandle,
                longReportsWritable ? FileAccess.ReadWrite : FileAccess.Read,
                longReportDevice.InputReportLength,
                isAsync: true);
            return new(
                shortReportDevice,
                longReportDevice,
                shortHandle,
                longHandle,
                shortStream,
                longStream);
        }
        catch
        {
            longHandle.Dispose();
            shortHandle.Dispose();
            throw;
        }
    }

    public async Task<HidppMessage> TransferAsync(
        HidppMessage request,
        int hidppVersion,
        bool ignoreFunctionId = false,
        CancellationToken cancellationToken = default)
    {
        var sent = WithSoftwareId(request, hidppVersion);
        await SendPackedAsync(sent, cancellationToken);

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(4));
        try
        {
            for (var unrelated = 0; unrelated < 10; unrelated++)
            {
                var response = await ReceiveFromEitherInterfaceAsync(timeout.Token);
                if (response.SubId is 0x8F or 0xFF)
                {
                    var data = response.Data.Span;
                    var code = data.Length > 1 ? data[1] : (byte)0xFF;
                    throw new HidppRemoteException(
                        response.SubId == 0x8F,
                        code,
                        sent.SubId,
                        sent.FunctionId);
                }

                var matchingDevice =
                    sent.DeviceId == response.DeviceId ||
                    sent.DeviceId == 0 ||
                    response.DeviceId == 0;
                if (matchingDevice &&
                    sent.SubId == response.SubId &&
                    (ignoreFunctionId || sent.FunctionId == response.FunctionId))
                {
                    return response;
                }
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException(
                "No matching HID++ response within 4 seconds. " +
                "Logi Options+ may be communicating with or blocking the receiver.");
        }

        throw new TimeoutException("Too many unrelated HID reports.");
    }

    public Task SendAsync(
        HidppMessage message,
        int hidppVersion,
        CancellationToken cancellationToken = default) =>
        SendPackedAsync(WithSoftwareId(message, hidppVersion), cancellationToken);

    public async Task<HidppMessage> ReceiveAsync(
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        using var timeoutSource =
            CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(timeout);
        try
        {
            return await ReceiveFromEitherInterfaceAsync(timeoutSource.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException($"No HID++ event within {timeout.TotalSeconds:0} seconds.");
        }
    }

    private static HidppMessage WithSoftwareId(HidppMessage message, int hidppVersion) =>
        hidppVersion >= 2
            ? message with
            {
                FunctionId = (byte)(message.FunctionId | HidppMessage.SoftwareId)
            }
            : message;

    private async Task SendPackedAsync(
        HidppMessage message,
        CancellationToken cancellationToken)
    {
        var wire = message.Pack();
        var stream = message.ReportId == HidppReportId.Short
            ? shortReportStream
            : longReportStream;
        var reportLength = message.ReportId == HidppReportId.Short
            ? shortReportDevice.OutputReportLength
            : longReportDevice.OutputReportLength;
        if (!stream.CanWrite)
        {
            throw new InvalidOperationException(
                $"HID++ report 0x{(byte)message.ReportId:X2} is read-only in this session.");
        }

        if (wire.Length > reportLength)
        {
            throw new HidppProtocolException(
                $"Output report is {reportLength} bytes, but HID++ needs {wire.Length}.");
        }

        var output = new byte[reportLength];
        wire.CopyTo(output, 0);
        await stream.WriteAsync(output, cancellationToken);
        await stream.FlushAsync(cancellationToken);
    }

    private async Task<HidppMessage> ReceiveFromEitherInterfaceAsync(
        CancellationToken cancellationToken)
    {
        using var oneRead = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var shortBuffer = new byte[shortReportDevice.InputReportLength];
        var longBuffer = new byte[longReportDevice.InputReportLength];
        var shortRead = ReadExactlyAsync(shortReportStream, shortBuffer, oneRead.Token);
        var longRead = ReadExactlyAsync(longReportStream, longBuffer, oneRead.Token);
        var completed = await Task.WhenAny(shortRead, longRead);
        await completed;
        oneRead.Cancel();
        await IgnoreCancellationAsync(completed == shortRead ? longRead : shortRead);
        var input = completed == shortRead ? shortBuffer : longBuffer;
        return HidppMessage.Unpack(input);
    }

    private static async Task IgnoreCancellationAsync(Task task)
    {
        try
        {
            await task;
        }
        catch (OperationCanceledException)
        {
        }
    }

    private static async Task ReadExactlyAsync(
        FileStream stream,
        byte[] buffer,
        CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(offset), cancellationToken);
            if (read == 0)
            {
                throw new EndOfStreamException("Bolt HID endpoint closed.");
            }

            offset += read;
        }
    }

    public async ValueTask DisposeAsync()
    {
        await longReportStream.DisposeAsync();
        await shortReportStream.DisposeAsync();
        longReportHandle.Dispose();
        shortReportHandle.Dispose();
    }
}

internal static class SafeHandleExtensions
{
    internal static int GetLastWin32Error(this SafeFileHandle _) =>
        System.Runtime.InteropServices.Marshal.GetLastWin32Error();
}
