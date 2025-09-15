<?php
/**
 * WHMCS Dependency Checker
 *
 * This script checks if the server environment meets the requirements
 * for running the specified WHMCS version.
 */

// Get WHMCS version from environment variable or default to latest
$whmcsVersion = getenv('WHMCS_VERSION') ?: '8.12.1';

// Define requirements for each WHMCS version
$versionRequirements = [
    '7.7.1' => [
        'php' => '7.2.0',
        'php_max' => '7.4.99',
        'mysql' => '5.7.0',
        'mariadb' => '10.3.0',
        'extensions' => [
            'curl', 'gd', 'imap', 'json', 'mbstring', 'pdo', 'pdo_mysql', 'soap', 'xml', 'zip', 'ioncube'
        ],
        'php_settings' => [
            'memory_limit' => '128M',
            'max_execution_time' => '60',
            'allow_url_fopen' => '1',
        ]
    ],
    '8.6.2' => [
        'php' => '7.4.0',
        'php_max' => '8.1.99',
        'mysql' => '5.7.0',
        'mariadb' => '10.3.0',
        'extensions' => [
            'curl', 'gd', 'imap', 'json', 'mbstring', 'pdo', 'pdo_mysql', 'soap', 'xml', 'zip', 'ioncube'
        ],
        'php_settings' => [
            'memory_limit' => '256M',
            'max_execution_time' => '120',
            'allow_url_fopen' => '1',
        ]
    ],
    '8.7.3' => [
        'php' => '8.0.0',
        'php_max' => '8.1.99',
        'mysql' => '5.7.0',
        'mariadb' => '10.3.0',
        'extensions' => [
            'curl', 'gd', 'imap', 'mbstring', 'pdo', 'pdo_mysql', 'soap', 'xml', 'zip'
        ],
        'php_settings' => [
            'memory_limit' => '256M',
            'max_execution_time' => '120',
            'allow_url_fopen' => '1',
        ]
    ],
    '8.10.1' => [
        'php' => '8.0.0',
        'php_max' => '8.1.99',
        'mysql' => '5.7.0',
        'mariadb' => '10.3.0',
        'extensions' => [
            'curl', 'gd', 'imap', 'mbstring', 'pdo', 'pdo_mysql', 'soap', 'xml', 'zip'
        ],
        'php_settings' => [
            'memory_limit' => '256M',
            'max_execution_time' => '120',
            'allow_url_fopen' => '1',
        ]
    ],
    '8.11.2' => [
        'php' => '8.1.0',
        'php_max' => '8.2.99',
        'mysql' => '8.0.0',
        'mariadb' => '10.5.0',
        'extensions' => [
            'curl', 'gd', 'imap', 'mbstring', 'pdo', 'pdo_mysql', 'soap', 'xml', 'zip'
        ],
        'php_settings' => [
            'memory_limit' => '256M',
            'max_execution_time' => '120',
            'allow_url_fopen' => '1',
        ]
    ],
    '8.11.3' => [
        'php' => '8.1.0',
        'php_max' => '8.2.99',
        'mysql' => '8.0.0',
        'mariadb' => '10.5.0',
        'extensions' => [
            'curl', 'gd', 'imap', 'mbstring', 'pdo', 'pdo_mysql', 'soap', 'xml', 'zip'
        ],
        'php_settings' => [
            'memory_limit' => '256M',
            'max_execution_time' => '120',
            'allow_url_fopen' => '1',
        ]
    ],
    '8.12.1' => [
        'php' => '8.1.0',
        'php_max' => '8.2.99',
        'mysql' => '8.0.0',
        'mariadb' => '10.5.0',
        'extensions' => [
            'curl', 'gd', 'imap', 'mbstring', 'pdo', 'pdo_mysql', 'soap', 'xml', 'zip'
        ],
        'php_settings' => [
            'memory_limit' => '256M',
            'max_execution_time' => '120',
            'allow_url_fopen' => '1',
        ]
    ],
];

/**
 * Helper function to check if a version meets minimum requirements
 */
function versionCheck($current, $required) {
    return version_compare($current, $required, '>=');
}

/**
 * Helper function to check if a version is below maximum allowed
 */
function versionMaxCheck($current, $max) {
    return version_compare($current, $max, '<=');
}

/**
 * Helper function to format check results
 */
function formatCheckResult($name, $currentValue, $requiredValue, $status) {
    $statusClass = $status ? 'passed' : 'failed';
    $statusText = $status ? 'PASSED' : 'FAILED';
    return "<tr class=\"{$statusClass}\">
                <td>{$name}</td>
                <td>{$currentValue}</td>
                <td>{$requiredValue}</td>
                <td class=\"status-{$statusClass}\">{$statusText}</td>
            </tr>";
}

function getDatabaseVersionInfo(): array
{
    $dbHost = getenv('WHMCS_DB_HOST') ?: 'db';
    $dbUser = getenv('WHMCS_DB_USER') ?: 'whmcs';
    $dbPass = getenv('WHMCS_DB_PASSWORD') ?: 'whmcs_password';

    try {
        $pdo = new PDO("mysql:host={$dbHost}", $dbUser, $dbPass, [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        ]);

        // Get raw version + vendor hint
        $stmt = $pdo->query('SELECT @@version AS version, @@version_comment AS comment');
        [$rawVersion, $comment] = $stmt->fetch(PDO::FETCH_NUM);

        // Detect engine
        $isMaria = (stripos($rawVersion, 'mariadb') !== false) || (stripos((string)$comment, 'mariadb') !== false);
        $engine  = $isMaria ? 'mariadb' : 'mysql';

        // Extract plain x.y.z
        $cleanVersion = null;
        if (preg_match('/\d+\.\d+\.\d+/', (string)$rawVersion, $m)) {
            $cleanVersion = $m[0];
        }

        return [
            'engine'       => $engine,
            'version'      => $cleanVersion,
            'raw_version'  => $rawVersion,
            'comment'      => $comment,
        ];
    } catch (PDOException $e) {
        return [
            'engine'      => 'unknown',
            'version'     => null,
            'raw_version' => null,
            'comment'     => null,
            'error'       => "Connection error: {$e->getMessage()}",
        ];
    }
}

/**
 * Check if IonCube Loader is installed
 */
function checkIonCube() {
    if (function_exists('ioncube_loader_version')) {
        return ioncube_loader_version();
    }

    // Alternative detection method
    $loaders = get_loaded_extensions();
    foreach ($loaders as $extension) {
        if (strpos(strtolower($extension), 'ioncube') !== false) {
            return "Installed (version unknown)";
        }
    }

    ob_start();
    phpinfo(INFO_MODULES);
    $contents = ob_get_clean();

    if (strpos($contents, 'ionCube') !== false) {
        return "Installed (version unknown)";
    }

    return "Not installed";
}

// Run the checks
$phpVersion = phpversion();
$databaseVersion = getDatabaseVersionInfo();
$ionCubeVersion = checkIonCube();
$requiredExtensions = $versionRequirements[$whmcsVersion]['extensions'] ?? [];
$phpSettings = $versionRequirements[$whmcsVersion]['php_settings'] ?? [];

$phpVersionCheck = versionCheck($phpVersion, $versionRequirements[$whmcsVersion]['php']);
$phpMaxVersionCheck = versionMaxCheck($phpVersion, $versionRequirements[$whmcsVersion]['php_max']);
$phpVersionCheckResult = $phpVersionCheck && $phpMaxVersionCheck;

$databaseVersionCheckResult = false;
if ($databaseVersion['engine'] !== 'unknown') {
    $databaseVersionCheckResult = versionCheck(
        $databaseVersion['version'],
        $versionRequirements[$whmcsVersion][$databaseVersion['engine']]
    );
}

// Check if all required extensions are installed
$extensionResults = [];
foreach ($requiredExtensions as $extension) {
    if ($extension === 'ioncube') {
        $extensionResults[$extension] = ($ionCubeVersion !== 'Not installed');
    } else {
        $extensionResults[$extension] = extension_loaded($extension);
    }
}

// Check PHP settings
$settingResults = [];
foreach ($phpSettings as $setting => $requiredValue) {
    $currentValue = ini_get($setting);

    // Convert memory value to bytes for comparison
    if ($setting === 'memory_limit') {
        $currentValueBytes = return_bytes($currentValue);
        $requiredValueBytes = return_bytes($requiredValue);
        $settingResults[$setting] = $currentValueBytes >= $requiredValueBytes;
    }
    // Check numeric values
    elseif (is_numeric($requiredValue)) {
        $settingResults[$setting] = (int)$currentValue >= (int)$requiredValue;
    }
    // Check On/Off values
    else {
        $settingResults[$setting] = strtolower($currentValue) === strtolower($requiredValue);
    }
}

/**
 * Convert PHP memory values to bytes
 */
function return_bytes($val) {
    $val = trim($val);
    $last = strtolower($val[strlen($val)-1]);
    $val = (int)$val;

    switch($last) {
        case 'g': $val *= 1024;
        case 'm': $val *= 1024;
        case 'k': $val *= 1024;
    }

    return $val;
}

// Overall result
$allChecksPassed = $phpVersionCheckResult && $databaseVersionCheckResult &&
    !in_array(false, $extensionResults) &&
    !in_array(false, $settingResults);

// Generate the HTML
?>
<!DOCTYPE html>
<html>
<head>
    <title>WHMCS Dependency Checker - Version <?php echo htmlspecialchars($whmcsVersion); ?></title>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            line-height: 1.6;
            color: #333;
            max-width: 1000px;
            margin: 0 auto;
            padding: 20px;
        }
        h1 {
            color: #2c3e50;
            border-bottom: 2px solid #3498db;
            padding-bottom: 10px;
        }
        .status-bar {
            padding: 15px;
            margin: 20px 0;
            border-radius: 5px;
            font-weight: bold;
            font-size: 18px;
        }
        .status-passed {
            background-color: #d4edda;
            color: #155724;
            border: 1px solid #c3e6cb;
        }
        .status-failed {
            background-color: #f8d7da;
            color: #721c24;
            border: 1px solid #f5c6cb;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
        }
        th, td {
            padding: 12px 15px;
            text-align: left;
            border-bottom: 1px solid #ddd;
        }
        th {
            background-color: #f8f9fa;
        }
        tr.failed {
            background-color: #ffe6e6;
        }
        tr.passed {
            background-color: #e6ffe6;
        }
        .status-passed {
            color: #28a745;
            font-weight: bold;
        }
        .status-failed {
            color: #dc3545;
            font-weight: bold;
        }
        .section {
            margin-bottom: 30px;
        }
        .summary {
            display: flex;
            gap: 20px;
            flex-wrap: wrap;
        }
        .summary-item {
            padding: 15px;
            border-radius: 5px;
            background-color: #f8f9fa;
            border: 1px solid #ddd;
            flex: 1;
            min-width: 200px;
        }
        .summary-item h3 {
            margin-top: 0;
            border-bottom: 1px solid #ddd;
            padding-bottom: 8px;
        }
        @media (max-width: 768px) {
            table {
                display: block;
                overflow-x: auto;
            }
        }
    </style>
</head>
<body>
<h1>WHMCS Dependency Checker</h1>

<div class="summary">
    <div class="summary-item">
        <h3>System Information</h3>
        <p><strong>WHMCS Version:</strong> <?php echo htmlspecialchars($whmcsVersion); ?></p>
        <p><strong>PHP Version:</strong> <?php echo htmlspecialchars($phpVersion); ?></p>
        <p><strong>MySQL Version:</strong> <?php echo htmlspecialchars($databaseVersion['version']); ?></p>
        <p><strong>Server:</strong> <?php echo htmlspecialchars($_SERVER['SERVER_SOFTWARE'] ?? 'Unknown'); ?></p>
    </div>

    <div class="summary-item">
        <h3>Overall Status</h3>
        <div class="status-bar <?php echo $allChecksPassed ? 'status-passed' : 'status-failed'; ?>">
            <?php echo $allChecksPassed ? 'All Checks Passed ✓' : 'Some Checks Failed ✗'; ?>
        </div>
        <p>This environment is <?php echo $allChecksPassed ? 'compatible' : 'not compatible'; ?> with WHMCS <?php echo htmlspecialchars($whmcsVersion); ?>.</p>
    </div>
</div>

<div class="section">
    <h2>Core Requirements</h2>
    <table>
        <thead>
        <tr>
            <th>Requirement</th>
            <th>Current Value</th>
            <th>Required Value</th>
            <th>Status</th>
        </tr>
        </thead>
        <tbody>
        <?php
        echo formatCheckResult(
            'PHP Version',
            $phpVersion,
            "{$versionRequirements[$whmcsVersion]['php']} - {$versionRequirements[$whmcsVersion]['php_max']}",
            $phpVersionCheckResult
        );

        echo formatCheckResult(
            ucfirst($databaseVersion['engine']) . ' Version',
            $databaseVersion['version'],
            ">= {$versionRequirements[$whmcsVersion][$databaseVersion['engine']]}",
            $databaseVersionCheckResult
        );

        if (in_array('ioncube', $requiredExtensions)) {
            echo formatCheckResult(
                'IonCube Loader',
                $ionCubeVersion,
                'Installed',
                $ionCubeVersion !== 'Not installed'
            );
        }
        ?>
        </tbody>
    </table>
</div>

<div class="section">
    <h2>PHP Extensions</h2>
    <table>
        <thead>
        <tr>
            <th>Extension</th>
            <th>Current Status</th>
            <th>Required</th>
            <th>Status</th>
        </tr>
        </thead>
        <tbody>
        <?php
        foreach ($extensionResults as $extension => $installed) {
            if ($extension !== 'ioncube') { // IonCube is already shown in core requirements
                echo formatCheckResult(
                    $extension,
                    $installed ? 'Installed' : 'Not installed',
                    'Installed',
                    $installed
                );
            }
        }
        ?>
        </tbody>
    </table>
</div>

<div class="section">
    <h2>PHP Settings</h2>
    <table>
        <thead>
        <tr>
            <th>Setting</th>
            <th>Current Value</th>
            <th>Required Value</th>
            <th>Status</th>
        </tr>
        </thead>
        <tbody>
        <?php
        foreach ($settingResults as $setting => $status) {
            echo formatCheckResult(
                $setting,
                ini_get($setting),
                $phpSettings[$setting],
                $status
            );
        }
        ?>
        </tbody>
    </table>
</div>

<div class="section">
    <h2>File System Permissions</h2>
    <table>
        <thead>
        <tr>
            <th>Directory</th>
            <th>Current Permissions</th>
            <th>Required</th>
            <th>Status</th>
        </tr>
        </thead>
        <tbody>
        <?php
        $directories = [
            'attachments' => '777',
            'downloads' => '777',
            'templates_c' => '777'
        ];

        foreach ($directories as $dir => $required) {
            $path = __DIR__ . '/' . $dir;
            $exists = is_dir($path);
            $writable = $exists && is_writable($path);

            if ($exists) {
                $perms = substr(sprintf('%o', fileperms($path)), -4);
            } else {
                $perms = 'Directory not found';
            }

            echo formatCheckResult(
                $dir,
                $perms,
                $required,
                $writable
            );
        }
        ?>
        </tbody>
    </table>
</div>

<div class="section">
    <p>
        <strong>Note:</strong> This dependency checker is for informational purposes only.
        Actual requirements may vary based on your specific WHMCS installation and plugins.
        Always refer to the official <a href="https://docs.whmcs.com/System_Requirements" target="_blank">WHMCS System Requirements</a> documentation.
    </p>
</div>
</body>
</html>
