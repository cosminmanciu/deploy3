<?php
/**
 * Configure WHMCS to use MailPit for email testing (Development Only)
 * This script should be executed after WHMCS installation in development environments
 */

// Only run in development environment
$environment = getenv('ENVIRONMENT') ?: 'production';
if ($environment !== 'development') {
    echo "MailPit configuration skipped - not in development environment\n";
    exit(0);
}

// Database connection settings from environment
$db_host = getenv('DB_HOST') ?: 'db';
$db_name = getenv('DB_NAME') ?: 'whmcs';
$db_user = getenv('DB_USER') ?: 'whmcs';
$db_password = getenv('DB_PASSWORD') ?: 'whmcs_password';

// MailPit SMTP settings
$smtp_host = getenv('SMTP_HOST') ?: 'mailpit';
$smtp_port = getenv('SMTP_PORT') ?: '1025';

try {
    // Connect to database
    $pdo = new PDO("mysql:host=$db_host;dbname=$db_name", $db_user, $db_password);
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

    echo "Connected to WHMCS database successfully\n";

    // Check if configuration table exists
    $tableCheck = $pdo->query("SHOW TABLES LIKE 'tblconfiguration'");
    if ($tableCheck->rowCount() === 0) {
        echo "WHMCS configuration table not found. Skipping MailPit configuration.\n";
        echo "Please run './whmcs.sh configure-mailpit' after WHMCS installation is complete.\n";
        exit(0); // Exit successfully to not break the setup process
    }

    // Update email configuration settings - using exact WHMCS field names
    $emailSettings = [
        'MailType' => 'smtp',
        'SMTPHost' => $smtp_host,
        'SMTPPort' => $smtp_port,
        'SMTPUsername' => '',
        'SMTPPassword' => '',
        'SMTPSSL' => '',
        'SMTPSecure' => '',
        'SMTPAuth' => '',
        'MailConfig' => 'wKEH+ZRibu1pLxTiVydrJkGmdFXgV0CaGKXy0SXyCOuO3b3wOHVh6jsY1MhqrWSUBSrsG/Cwd9Adt8jxbPCb9UWNxuE/snEkuLRJ5j5zGjAJEFFb/OOw8cBFs1L/RDXBymiA9g2igVvSG1LSxzCKVzDl32AaDzYtGh/cD7UJjnf08DnJIVH+BA75c5ktIIS6UmqvecNhs4amLTLuBdg7msdMwmzmkUWADiOl1kcayFkla4YEelMMz6gqe6lF0GUYgiZOx+ODzpJMj1ZX1E0Kh4R+G12BXsBuWNkoyKIV6DkJ8NyzXM6otirhPd72pVQUFepxr8Ku0a159X9KPD+rHn1gEyZ8M+JPMpeMvCiuM5PWRZkim2zBOokEkKRFIJ50yOE5jfJZRFTRechXmiaGaLCWwc0RRQ8vgIUAr39u/JPkX1iOtuUvyIwwk94qJwyqIf6hzU24tT/RMas0qmCDk12MwjpTuzg6Bo5XodBMX36iMB+Bo/IXHtvFbafRv68VFGZ80DRs6EqVTTKg',
        'EmailGlobalHeader' => '<div style="background-color: #ffe0e0; padding: 10px; margin-bottom: 20px; border: 1px solid #ff0000;">
            <strong>⚠️ Development Environment - MailPit</strong><br>
            This email was sent from a development environment using MailPit.<br>
            View all emails at: <a href="http://localhost:21025">http://localhost:21025</a>
        </div>',
    ];

    foreach ($emailSettings as $setting => $value) {
        // Check if setting exists
        $stmt = $pdo->prepare("SELECT COUNT(*) FROM tblconfiguration WHERE setting = :setting");
        $stmt->execute(['setting' => $setting]);
        $exists = $stmt->fetchColumn() > 0;

        if ($exists) {
            // Update existing setting
            $stmt = $pdo->prepare("UPDATE tblconfiguration SET value = :value WHERE setting = :setting");
            $stmt->execute(['value' => $value, 'setting' => $setting]);
            echo "Updated: $setting\n";
        } else {
            // Insert new setting
            $stmt = $pdo->prepare("INSERT INTO tblconfiguration (setting, value) VALUES (:setting, :value)");
            $stmt->execute(['setting' => $setting, 'value' => $value]);
            echo "Inserted: $setting\n";
        }
    }

    // Add system email settings
    $systemEmailSettings = [
        'SystemEmailsFromEmail' => 'noreply@whmcs.local',
        'SystemEmailsFromName' => 'WHMCS Development',
        'SystemEmailReplyTo' => 'support@whmcs.local',
    ];

    foreach ($systemEmailSettings as $setting => $value) {
        $stmt = $pdo->prepare("SELECT COUNT(*) FROM tblconfiguration WHERE setting = :setting");
        $stmt->execute(['setting' => $setting]);
        $exists = $stmt->fetchColumn() > 0;

        if ($exists) {
            $stmt = $pdo->prepare("UPDATE tblconfiguration SET value = :value WHERE setting = :setting");
            $stmt->execute(['value' => $value, 'setting' => $setting]);
            echo "Updated: $setting\n";
        } else {
            $stmt = $pdo->prepare("INSERT INTO tblconfiguration (setting, value) VALUES (:setting, :value)");
            $stmt->execute(['setting' => $setting, 'value' => $value]);
            echo "Inserted: $setting\n";
        }
    }

    echo "\n✅ MailPit configuration completed successfully!\n";
    echo "📧 SMTP Server: $smtp_host:$smtp_port\n";
    echo "🌐 MailPit Web UI: http://localhost:21025\n";
    echo "\nAll emails sent from WHMCS will now be captured by MailPit.\n";

} catch (PDOException $e) {
    echo "Error: " . $e->getMessage() . "\n";
    exit(1);
}
