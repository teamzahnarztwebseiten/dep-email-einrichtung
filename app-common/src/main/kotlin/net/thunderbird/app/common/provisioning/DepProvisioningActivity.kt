package net.thunderbird.app.common.provisioning

import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import app.k9mail.feature.account.common.domain.entity.Account
import app.k9mail.feature.account.common.domain.entity.AccountOptions
import app.k9mail.feature.account.server.validation.domain.ServerValidationDomainContract.UseCase.ValidateServerSettings
import app.k9mail.feature.account.setup.AccountSetupExternalContract.AccountCreator
import app.k9mail.feature.account.setup.AccountSetupExternalContract.AccountCreator.AccountCreatorResult
import com.fsck.k9.Preferences
import com.fsck.k9.mail.AuthType
import com.fsck.k9.mail.ConnectionSecurity
import com.fsck.k9.mail.ServerSettings
import com.fsck.k9.mail.server.ServerSettingsValidationResult
import java.io.File
import java.util.UUID
import kotlinx.coroutines.launch
import org.koin.android.ext.android.inject

/**
 * dentaleyepad: Richtet ein Mailkonto ohne Eingabe am Gerät ein.
 *
 * Wird vom Einrichtungsprogramm am PC per ADB gestartet, zum Beispiel:
 *
 * ```
 * adb shell am start -W -a de.dentaleyepad.mail.EINRICHTEN \
 *     -n de.dentaleyepad.mail/net.thunderbird.app.common.provisioning.DepProvisioningActivity \
 *     --es email dentaleyepad-12345@dentaleyepad.net --es password '...' --es password2 '...'
 * ```
 *
 * Die Activity ist durch die Berechtigung `android.permission.DUMP` geschützt. Diese Berechtigung hat
 * die ADB-Shell, normale Apps auf dem Gerät bekommen sie nicht. Andere Apps können also kein Konto
 * unterschieben.
 *
 * Ablauf:
 * 1. Gibt es das Konto schon, passiert nichts (Ergebnis `VORHANDEN`).
 * 2. Anmeldung am Posteingangsserver (IMAP) mit `password`. Klappt das nicht und ist `password2`
 *    angegeben, wird `password2` probiert (alte und neue Passwort-Regel).
 * 3. Anmeldung am Postausgangsserver (SMTP) mit dem passenden Passwort.
 * 4. Konto anlegen.
 *
 * Das Ergebnis steht im Logcat (Tag `DepEinrichtung`) und in der Datei
 * `/sdcard/Android/data/<paket>/files/einrichtung-status.txt`. Die erste Zeile ist eines von:
 * `OK`, `OK_PASSWORT2`, `VORHANDEN`, `FEHLER_ANMELDUNG`, `FEHLER_NETZWERK`, `FEHLER_ZERTIFIKAT`,
 * `FEHLER_EINGABE`, `FEHLER`. Passwörter werden nie protokolliert.
 */
class DepProvisioningActivity : ComponentActivity() {

    private val preferences: Preferences by inject()
    private val validateServerSettings: ValidateServerSettings by inject()
    private val accountCreator: AccountCreator by inject()

    private lateinit var statusView: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        statusView = TextView(this).apply {
            gravity = Gravity.CENTER
            textSize = TEXT_SIZE_SP
            setPadding(PADDING_PX, PADDING_PX, PADDING_PX, PADDING_PX)
            text = "E-Mail-Konto wird eingerichtet …"
        }
        setContentView(statusView)

        if (savedInstanceState == null) {
            lifecycleScope.launch { runProvisioning() }
        }
    }

    @Suppress("TooGenericExceptionCaught")
    private suspend fun runProvisioning() {
        val result = try {
            provision()
        } catch (e: Exception) {
            Log.e(TAG, "Unerwarteter Fehler bei der Einrichtung", e)
            Result(Status.FEHLER, e.javaClass.simpleName)
        }
        report(result)
    }

    @Suppress("ReturnCount")
    private suspend fun provision(): Result {
        val email = intent.getStringExtra(EXTRA_EMAIL)?.trim().orEmpty()
        val password = intent.getStringExtra(EXTRA_PASSWORD).orEmpty()
        val password2 = intent.getStringExtra(EXTRA_PASSWORD2)?.takeIf { it.isNotEmpty() }
        val host = intent.getStringExtra(EXTRA_HOST)?.trim()?.takeIf { it.isNotEmpty() } ?: DEFAULT_HOST
        val name = intent.getStringExtra(EXTRA_NAME)?.trim()?.takeIf { it.isNotEmpty() } ?: email

        if (!EMAIL_REGEX.matches(email) || password.isEmpty()) {
            return Result(Status.FEHLER_EINGABE, "email oder password fehlt")
        }

        if (preferences.getAccounts().any { it.email.equals(email, ignoreCase = true) }) {
            return Result(Status.VORHANDEN, email)
        }

        setStatusText("Anmeldung am Mailserver wird geprüft …")

        var usedPassword = password
        var incomingResult = validateServerSettings.execute(incomingSettings(host, email, password))
        if (incomingResult is ServerSettingsValidationResult.AuthenticationError && password2 != null) {
            Log.i(TAG, "Passwort 1 abgelehnt, versuche Passwort 2")
            usedPassword = password2
            incomingResult = validateServerSettings.execute(incomingSettings(host, email, password2))
        }
        incomingResult.toFailure("IMAP")?.let { return it }

        val outgoingResult = validateServerSettings.execute(outgoingSettings(host, email, usedPassword))
        outgoingResult.toFailure("SMTP")?.let { return it }

        setStatusText("Konto wird angelegt …")

        val account = Account(
            uuid = UUID.randomUUID().toString(),
            emailAddress = email,
            incomingServerSettings = incomingSettings(host, email, usedPassword),
            outgoingServerSettings = outgoingSettings(host, email, usedPassword),
            authorizationState = null,
            specialFolderSettings = null,
            options = AccountOptions(
                accountName = name,
                displayName = name,
                emailSignature = null,
                checkFrequencyInMinutes = CHECK_FREQUENCY_MINUTES,
                messageDisplayCount = MESSAGE_DISPLAY_COUNT,
                showNotification = true,
            ),
        )

        return when (val created = accountCreator.createAccount(account)) {
            is AccountCreatorResult.Success -> {
                val status = if (usedPassword == password) Status.OK else Status.OK_PASSWORT2
                Result(status, email)
            }
            is AccountCreatorResult.Error -> Result(Status.FEHLER, created.message)
        }
    }

    private fun ServerSettingsValidationResult.toFailure(server: String): Result? {
        return when (this) {
            ServerSettingsValidationResult.Success -> null
            is ServerSettingsValidationResult.AuthenticationError ->
                Result(Status.FEHLER_ANMELDUNG, "$server: ${serverMessage.orEmpty()}")
            is ServerSettingsValidationResult.NetworkError ->
                Result(Status.FEHLER_NETZWERK, "$server: ${exception.message.orEmpty()}")
            is ServerSettingsValidationResult.CertificateError ->
                Result(Status.FEHLER_ZERTIFIKAT, server)
            is ServerSettingsValidationResult.ServerError ->
                Result(Status.FEHLER, "$server: ${serverMessage.orEmpty()}")
            is ServerSettingsValidationResult.MissingServerCapabilityError ->
                Result(Status.FEHLER, "$server: $capabilityName fehlt")
            is ServerSettingsValidationResult.ClientCertificateError ->
                Result(Status.FEHLER, "$server: Client-Zertifikat")
            is ServerSettingsValidationResult.UnknownError ->
                Result(Status.FEHLER, "$server: ${exception.message.orEmpty()}")
        }
    }

    private fun report(result: Result) {
        val line = "${result.status.name}\n${result.detail}\n"
        Log.i(TAG, "ERGEBNIS ${result.status.name} ${result.detail}")

        try {
            getExternalFilesDir(null)?.let { dir -> File(dir, STATUS_FILE_NAME).writeText(line) }
        } catch (e: java.io.IOException) {
            Log.w(TAG, "Statusdatei konnte nicht geschrieben werden", e)
        }

        val success = result.status in setOf(Status.OK, Status.OK_PASSWORT2, Status.VORHANDEN)
        setStatusText(
            if (success) {
                "E-Mail-Konto ist eingerichtet."
            } else {
                "Einrichtung fehlgeschlagen:\n${result.status.name}\n${result.detail}"
            },
        )
        setResult(if (success) RESULT_OK else RESULT_CANCELED)

        if (success) {
            statusView.postDelayed({ finish() }, FINISH_DELAY_MS)
        }
    }

    private fun setStatusText(text: String) {
        runOnUiThread { statusView.text = text }
    }

    private enum class Status {
        OK,
        OK_PASSWORT2,
        VORHANDEN,
        FEHLER_ANMELDUNG,
        FEHLER_NETZWERK,
        FEHLER_ZERTIFIKAT,
        FEHLER_EINGABE,
        FEHLER,
    }

    private data class Result(val status: Status, val detail: String)

    companion object {
        private const val TAG = "DepEinrichtung"
        private const val STATUS_FILE_NAME = "einrichtung-status.txt"

        const val EXTRA_EMAIL = "email"
        const val EXTRA_PASSWORD = "password"
        const val EXTRA_PASSWORD2 = "password2"
        const val EXTRA_HOST = "host"
        const val EXTRA_NAME = "name"

        private const val DEFAULT_HOST = "mail.dentaleyepad.net"
        private const val IMAP_PORT = 993
        private const val SMTP_PORT = 465

        // Wie der Standard im Einrichtungsassistenten: alle 15 Minuten nach neuen Mails sehen
        private const val CHECK_FREQUENCY_MINUTES = 15
        private const val MESSAGE_DISPLAY_COUNT = 100

        private const val TEXT_SIZE_SP = 20f
        private const val PADDING_PX = 48
        private const val FINISH_DELAY_MS = 1500L

        private val EMAIL_REGEX = Regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$")

        private fun incomingSettings(host: String, email: String, password: String) = ServerSettings(
            type = "imap",
            host = host,
            port = IMAP_PORT,
            connectionSecurity = ConnectionSecurity.SSL_TLS_REQUIRED,
            authenticationType = AuthType.PLAIN,
            username = email,
            password = password,
            clientCertificateAlias = null,
        )

        private fun outgoingSettings(host: String, email: String, password: String) = ServerSettings(
            type = "smtp",
            host = host,
            port = SMTP_PORT,
            connectionSecurity = ConnectionSecurity.SSL_TLS_REQUIRED,
            authenticationType = AuthType.PLAIN,
            username = email,
            password = password,
            clientCertificateAlias = null,
        )
    }
}
