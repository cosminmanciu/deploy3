-- Trusted Proxies Configuration for WHMCS
-- This script sets up trusted proxy IPs for production and staging environments
-- Only runs if the trustedProxyIps setting doesn't already exist

-- Check if the setting already exists
SET @exists = (SELECT COUNT(*) FROM tblconfiguration WHERE setting = 'trustedProxyIps');

-- Only insert if it doesn't exist
INSERT INTO tblconfiguration (setting, value, created_at, updated_at)
SELECT 
    'trustedProxyIps',
    '[{"ip":"10.0.0.0/8","note":"IngressController"},{"ip":"172.16.0.0/12","note":"Docker Internal"},{"ip":"192.168.0.0/16","note":"Private Network"},{"ip":"172.18.0.0/16","note":"Docker Bridge"},{"ip":"127.0.0.0/8","note":"Localhost"}]',
    NOW(),
    NOW()
WHERE @exists = 0;

-- Log the action
SELECT CASE 
    WHEN @exists = 0 THEN 'Trusted proxy IPs configured successfully'
    ELSE 'Trusted proxy IPs already configured - skipping'
END AS status;