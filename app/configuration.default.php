<?php
require_once 'vendor/TeamBlue/vendor/autoload.php';
$license = getenv('LICENSE') ?: 'Dev-fa80dc3463fb1e5ac558';
$db_host = getenv('DB_HOST') ?: 'db';
$db_port = getenv('DB_PORT') ?: '';
$db_username = getenv('DB_USER') ?: 'whmcs';
$db_password = getenv('DB_PASSWORD') ?: 'whmcs_password';
$db_name = getenv('DB_NAME') ?: 'whmcs';
$db_tls_ca = '';
$db_tls_ca_path = '';
$db_tls_cert = '';
$db_tls_cipher = '';
$db_tls_key = '';
$db_tls_verify_cert = '';
$cc_encryption_hash = getenv('CC_ENCRYPTION_HASH') ?: 'kc22UxYbklPT4iWI49O2kEJIx5lQkFsimWLr3SWf02c1jM8PRyCcqyL3fL5MH56J';
$templates_compiledir = 'templates_c';
