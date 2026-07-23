using System.Windows;
using System.Windows.Controls;

namespace BoltUpdateTool.Windows;

public partial class FlashConfirmationWindow : Window
{
    public FlashConfirmationWindow() => InitializeComponent();

    private void ConfirmationText_TextChanged(object sender, TextChangedEventArgs e) =>
        ConfirmButton.IsEnabled = ConfirmationText.Text == "FLASH";

    private void ConfirmButton_Click(object sender, RoutedEventArgs e)
    {
        if (ConfirmationText.Text != "FLASH")
        {
            return;
        }

        DialogResult = true;
    }
}
