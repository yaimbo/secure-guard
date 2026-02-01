/// Email templates for MinnowVPN notifications
class EmailTemplates {
  /// HTML template for enrollment email
  static String enrollmentHtml({
    required String name,
    required String code,
    required String deepLink,
    required String serverDomain,
    required String expiresIn,
  }) {
    return '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Your VPN Access is Ready</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
      line-height: 1.6;
      color: #333;
      max-width: 600px;
      margin: 0 auto;
      padding: 20px;
    }
    .header {
      text-align: center;
      padding: 20px 0;
      border-bottom: 2px solid #3B82F6;
    }
    .header h1 {
      color: #1E40AF;
      margin: 0;
      font-size: 24px;
    }
    .content {
      padding: 30px 0;
    }
    .button {
      display: inline-block;
      background-color: #3B82F6;
      color: white !important;
      padding: 14px 28px;
      text-decoration: none;
      border-radius: 8px;
      font-weight: 600;
      margin: 20px 0;
    }
    .button:hover {
      background-color: #2563EB;
    }
    .code-box {
      background-color: #F3F4F6;
      border: 1px solid #E5E7EB;
      border-radius: 8px;
      padding: 20px;
      margin: 20px 0;
    }
    .code {
      font-family: 'Courier New', monospace;
      font-size: 18px;
      font-weight: bold;
      color: #1F2937;
      letter-spacing: 2px;
    }
    .instructions {
      margin: 20px 0;
    }
    .instructions li {
      margin: 8px 0;
    }
    .footer {
      border-top: 1px solid #E5E7EB;
      padding-top: 20px;
      margin-top: 30px;
      font-size: 12px;
      color: #6B7280;
    }
    .warning {
      color: #DC2626;
      font-weight: 500;
    }
  </style>
</head>
<body>
  <div class="header">
    <h1>MinnowVPN</h1>
  </div>

  <div class="content">
    <p>Hi $name,</p>

    <p>You've been granted VPN access. Click the button below to set up MinnowVPN on your device:</p>

    <p style="text-align: center;">
      <a href="$deepLink" class="button">Set Up VPN</a>
    </p>

    <div class="code-box">
      <p style="margin: 0 0 10px 0;"><strong>If the button doesn't work, enter these details manually in the MinnowVPN app:</strong></p>
      <ul class="instructions" style="margin: 0; padding-left: 20px;">
        <li>Server: <span class="code">$serverDomain</span></li>
        <li>Enrollment Code: <span class="code">$code</span></li>
      </ul>
    </div>

    <p class="warning">This enrollment code expires in $expiresIn.</p>

    <h3>Quick Start Guide</h3>
    <ol class="instructions">
      <li>Download the MinnowVPN app for your device (if you haven't already)</li>
      <li>Click the "Set Up VPN" button above, or enter the code manually</li>
      <li>The app will automatically configure and connect</li>
    </ol>

    <p>Need help? Contact your IT administrator.</p>
  </div>

  <div class="footer">
    <p>This is an automated message from MinnowVPN. Please do not reply to this email.</p>
    <p>If you did not request VPN access, please contact your IT administrator immediately.</p>
  </div>
</body>
</html>
''';
  }

  /// Plain text template for enrollment email
  static String enrollmentText({
    required String name,
    required String code,
    required String deepLink,
    required String serverDomain,
    required String expiresIn,
  }) {
    return '''
MinnowVPN - Your Access is Ready

Hi $name,

You've been granted VPN access. Use the link below to set up MinnowVPN on your device:

$deepLink

If the link doesn't work, open the MinnowVPN app and enter:
  - Server: $serverDomain
  - Enrollment Code: $code

This enrollment code expires in $expiresIn.

Quick Start Guide:
1. Download the MinnowVPN app for your device (if you haven't already)
2. Click the link above, or enter the code manually
3. The app will automatically configure and connect

Need help? Contact your IT administrator.

---
This is an automated message from MinnowVPN.
If you did not request VPN access, please contact your IT administrator immediately.
''';
  }

  /// HTML template for test email
  static String testEmailHtml() {
    return '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>MinnowVPN Test Email</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
      line-height: 1.6;
      color: #333;
      max-width: 600px;
      margin: 0 auto;
      padding: 20px;
    }
    .success {
      background-color: #D1FAE5;
      border: 1px solid #10B981;
      border-radius: 8px;
      padding: 20px;
      text-align: center;
    }
    .success h2 {
      color: #059669;
      margin: 0 0 10px 0;
    }
  </style>
</head>
<body>
  <div class="success">
    <h2>Email Configuration Successful</h2>
    <p>Your MinnowVPN SMTP settings are working correctly.</p>
  </div>
  <p style="margin-top: 20px; font-size: 12px; color: #6B7280;">
    This is a test email from MinnowVPN. No action is required.
  </p>
</body>
</html>
''';
  }

  /// Plain text template for test email
  static String testEmailText() {
    return '''
MinnowVPN - Test Email

Email Configuration Successful!

Your MinnowVPN SMTP settings are working correctly.

---
This is a test email from MinnowVPN. No action is required.
''';
  }
}
