using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Windows.Navigation;
using System.Windows;
using System.Windows.Media;
using Bolt.Protocol;
using Bolt.WindowsHid;
using Microsoft.Win32;

namespace BoltUpdateTool.Windows;

public partial class MainWindow : Window
{
    public ObservableCollection<string> LogLines { get; } = [];
    private IReadOnlyList<ValidatedFirmwareImage>? selectedFirmware;
    private bool isBusy;

    public MainWindow()
    {
        InitializeComponent();
        DataContext = this;
    }

    private async void Window_Loaded(object sender, RoutedEventArgs e) =>
        await RefreshAsync();

    private async void RefreshButton_Click(object sender, RoutedEventArgs e) =>
        await RefreshAsync();

    private async Task RefreshAsync()
    {
        if (isBusy)
        {
            return;
        }

        isBusy = true;
        RefreshButton.IsEnabled = false;
        SelectFirmwareButton.IsEnabled = false;
        StartUpdateButton.IsEnabled = false;
        FirmwareGrid.ItemsSource = null;
        SetStatus("Searching for receiver …", string.Empty, "#FFF59E0B");
        Log("Searching all HID interfaces for 046D:C548.");

        try
        {
            var interfaces = await Task.Run(BoltDeviceLocator.ListRuntimeInterfaces);
            if (interfaces.Count == 0)
            {
                throw new InvalidOperationException(
                    "No connected Bolt receiver 046D:C548 was found.");
            }

            foreach (var device in interfaces)
            {
                Log(
                    $"{device.VendorId:X4}:{device.ProductId:X4} " +
                    $"UsagePage=0x{device.UsagePage:X4} Usage=0x{device.Usage:X4} " +
                    $"Input={device.InputReportLength} Output={device.OutputReportLength} " +
                    $"Feature={device.FeatureReportLength}");
                Log($"  {device.DevicePath}");
            }

            var runtime = await Task.Run(BoltDeviceLocator.FindRuntimeHidppInterfaces);
            Log("Opening FF00:0001 for short reports.");
            Log("Opening FF00:0002 read-only for long-report replies.");

            await using var transport = WindowsHidppTransport.OpenRuntime(
                runtime.ShortReports,
                runtime.LongReports);
            var session = new Hidpp10BoltSession(transport);
            var protocol = await session.PingAsync();
            Log($"HID++ ping succeeded: protocol {protocol}.0.");

            await session.PrepareAsync();
            var entities = await session.GetFirmwareEntitiesAsync();
            FirmwareGrid.ItemsSource = entities;
            foreach (var entity in entities)
            {
                Log(
                    $"Entity {entity.Index}: {entity.KindDescription}, " +
                    $"{entity.Version}, active={entity.Active}");
            }

            SetStatus(
                "Bolt receiver ready",
                $"{runtime.ShortReports.Product} · 046D:C548 · HID++ {protocol}.0 · " +
                $"{entities.Count} Firmware-Entities",
                "#FF16A34A");
        }
        catch (Exception error)
        {
            Log($"ERROR: {error.Message}");
            SetStatus(
                "Could not read receiver",
                error.Message,
                "#FFDC2626");
        }
        finally
        {
            isBusy = false;
            RefreshButton.IsEnabled = true;
            SelectFirmwareButton.IsEnabled = true;
            StartUpdateButton.IsEnabled = selectedFirmware is not null;
            if (LogList.Items.Count > 0)
            {
                LogList.ScrollIntoView(LogList.Items[^1]);
            }
        }
    }

    private void SelectFirmwareButton_Click(object sender, RoutedEventArgs e)
    {
        if (isBusy)
        {
            return;
        }

        var dialog = new OpenFileDialog
        {
            Title = "Select application and radio/secondary DFU files",
            Filter = "Unpacked DFU files (*.dfu)|*.dfu",
            Multiselect = true,
            CheckFileExists = true
        };
        if (dialog.ShowDialog(this) != true)
        {
            return;
        }

        try
        {
            if (dialog.FileNames.Length != 2)
            {
                throw new HidppProtocolException(
                    "Exactly two unpacked .dfu files must be selected.");
            }

            var files = dialog.FileNames
                .Select(path =>
                    (Path.GetFileName(path), (ReadOnlyMemory<byte>)File.ReadAllBytes(path)))
                .ToArray();
            selectedFirmware = FirmwarePackageValidator.Validate(files)
                .OrderBy(image => image.Kind)
                .ToArray();
            var application = selectedFirmware.Single(
                image => image.Kind == FirmwareImageKind.Application);
            var secondary = selectedFirmware.Single(
                image => image.Kind == FirmwareImageKind.Secondary);
            FirmwareSelectionText.Text = "Compatible Bolt C548 package MPR05_D0";
            FirmwareFilesText.Text =
                $"Application: {application.FileName} ({application.Data.Length:N0} bytes)\n" +
                $"Radio / secondary: {secondary.FileName} ({secondary.Data.Length:N0} bytes)";
            StartUpdateButton.IsEnabled = true;
            Log(
                $"Firmware package validated: {application.FileName} + " +
                $"{secondary.FileName}.");
        }
        catch (Exception error)
        {
            selectedFirmware = null;
            FirmwareSelectionText.Text = "Firmware package rejected";
            FirmwareFilesText.Text = error.Message;
            StartUpdateButton.IsEnabled = false;
            Log($"Firmware selection failed: {error.Message}");
            MessageBox.Show(
                this,
                error.Message,
                "Invalid firmware package",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }

    private async void StartUpdateButton_Click(object sender, RoutedEventArgs e)
    {
        if (isBusy || selectedFirmware is null)
        {
            return;
        }

        var confirmation = new FlashConfirmationWindow
        {
            Owner = this
        };
        if (confirmation.ShowDialog() != true)
        {
            Log("Firmware update canceled by the user.");
            return;
        }

        isBusy = true;
        RefreshButton.IsEnabled = false;
        SelectFirmwareButton.IsEnabled = false;
        StartUpdateButton.IsEnabled = false;
        UpdateStageText.Visibility = Visibility.Visible;
        UpdateProgress.Visibility = Visibility.Visible;
        UpdateProgress.IsIndeterminate = true;
        FirmwareGrid.ItemsSource = null;
        Log("Firmware update explicitly confirmed.");

        try
        {
            var progress = new Progress<DfuProgress>(value =>
            {
                UpdateProgress.IsIndeterminate = false;
                UpdateProgress.Maximum = value.PacketCount;
                UpdateProgress.Value = value.PacketIndex;
                UpdateStageText.Text =
                    $"Writing packet {value.PacketIndex:N0} of {value.PacketCount:N0}. " +
                    "Do not unplug the receiver.";
            });
            var result = await BoltFirmwareUpdater.UpdateAsync(
                selectedFirmware,
                progress,
                (stage, message) =>
                {
                    UpdateStageText.Text = message;
                    UpdateProgress.IsIndeterminate =
                        stage is not FirmwareUpdateStage.Flashing and
                            not FirmwareUpdateStage.Completed;
                    Log($"{stage}: {message}");
                },
                Log);

            FirmwareGrid.ItemsSource = result.Entities;
            UpdateProgress.IsIndeterminate = false;
            UpdateProgress.Maximum = 1;
            UpdateProgress.Value = 1;
            SetStatus(
                "Firmware update complete",
                string.Join(
                    " · ",
                    result.Entities.Select(entity => entity.Version)),
                "#FF16A34A");
            MessageBox.Show(
                this,
                "Both firmware entities were transferred. The Bolt receiver returned " +
                "as C548 and its firmware information was read successfully.",
                "Update complete",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }
        catch (Exception error)
        {
            Log($"FLASH FAILED: {error.Message}");
            UpdateStageText.Text =
                "Update stopped: " + error.Message +
                "\nIf the receiver is detected as AB07, restart the update using " +
                "the same validated package.";
            UpdateProgress.IsIndeterminate = false;
            SetStatus("Firmware update failed", error.Message, "#FFDC2626");
            MessageBox.Show(
                this,
                error.Message,
                "Firmware update failed",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
        finally
        {
            isBusy = false;
            RefreshButton.IsEnabled = true;
            SelectFirmwareButton.IsEnabled = true;
            StartUpdateButton.IsEnabled = selectedFirmware is not null;
        }
    }

    private void Log(string message) =>
        LogLines.Add($"[{DateTime.Now:HH:mm:ss}] {message}");

    private void SetStatus(string status, string detail, string color)
    {
        StatusText.Text = status;
        DeviceText.Text = detail;
        StatusIndicator.Fill = (Brush)new BrushConverter().ConvertFromString(color)!;
    }

    private void HomepageLink_RequestNavigate(
        object sender,
        RequestNavigateEventArgs e)
    {
        Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri)
        {
            UseShellExecute = true
        });
        e.Handled = true;
    }
}
