#!/bin/bash
# Reload Apple modules after hibernate resume
exec >> /var/log/hibernate-post.log 2>&1
echo "=== $(date) post-resume ==="
sleep 2
echo "loading spi stack..."; modprobe -v spi_pxa2xx_core; modprobe -v spi_pxa2xx_platform; echo "rc=$?"
echo "loading applespi..."; modprobe -v applespi; echo "rc=$?"
echo "loading applesmc..."; modprobe -v applesmc; echo "rc=$?"
echo "loading brcmfmac..."; modprobe -v brcmfmac; echo "rc=$?"
echo "loading hci_uart..."; modprobe -v hci_uart; echo "rc=$?"
echo "loading facetimehd..."; modprobe -v facetimehd; echo "rc=$?"
echo "loading acpi_call..."; modprobe -v acpi_call; echo "rc=$?"
echo "--- lsmod check ---"
lsmod | grep -iE 'apple|brcm|facetime|spi_pxa|hci_uart|acpi_call'
echo "=== done ==="
sync
