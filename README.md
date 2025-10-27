# Orange Pi RV2 Debian Image Builder


This script builds a Debian image for the Orange Pi RV2 single-board computer.

## Prerequisites

Before you begin, ensure you have the following software installed on your system:

*   **Git:** For cloning the repository.
*   **balenaEtcher:** For flashing the generated image to an SD card. You can download it from the [official website](https://www.balena.io/etcher/).

## How to Use

1.  **Clone the repository:**

    ```bash
    git clone https://github.com/zerokaze420/build_image_script.git
    ```

2.  **Navigate to the project directory:**

    ```bash
    cd build_image_script/
    ```

3.  **Make the script executable:**

    ```bash
    chmod +x main.sh
    ```

4.  **Run the build script:**

    ```bash
    ./main.sh
    ```

5.  **Flash the image:**

    After the script finishes, you will find the generated image file in the project directory. Use balenaEtcher to flash the image onto your SD card.

## Features

*   **Lightweight:** The generated Debian image is minimal and optimized for the Orange Pi RV2.
*   **Easy to Use:** The build process is automated with a single script.
*   **Customizable:** You can easily modify the build script to add or remove packages and configurations.

## Disclaimer

This script is provided as-is. The author is not responsible for any damage to your device. Use it at your own risk.
