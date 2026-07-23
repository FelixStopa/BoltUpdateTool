namespace Bolt.Protocol;

public interface IHidppTransport : IAsyncDisposable
{
    Task SendAsync(
        HidppMessage message,
        int hidppVersion,
        CancellationToken cancellationToken = default);

    Task<HidppMessage> ReceiveAsync(
        TimeSpan timeout,
        CancellationToken cancellationToken = default);

    Task<HidppMessage> TransferAsync(
        HidppMessage request,
        int hidppVersion,
        bool ignoreFunctionId = false,
        CancellationToken cancellationToken = default);
}
