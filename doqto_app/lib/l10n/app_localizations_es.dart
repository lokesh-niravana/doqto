// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get settingsTitle => 'Ajustes';

  @override
  String get settingsAccount => 'Cuenta';

  @override
  String get settingsPrivacy => 'Privacidad';

  @override
  String get settingsPrivacySubtitle =>
      'Última conexión, confirmaciones de lectura, quién puede contactarte';

  @override
  String get settingsAppearance => 'Chats y apariencia';

  @override
  String get settingsAppearanceSubtitle =>
      'Tema, color del chat, fondo, tamaño de letra';

  @override
  String get settingsNotifications => 'Notificaciones';

  @override
  String get settingsNotificationsSubtitle =>
      'Tonos, vibración, vistas previas';

  @override
  String get settingsStorage => 'Almacenamiento y datos';

  @override
  String get settingsStorageSubtitle => 'Archivos, descargas y uso';

  @override
  String get settingsLanguage => 'Idioma de la app';

  @override
  String get settingsHelp => 'Ayuda';

  @override
  String get settingsHelpSubtitle =>
      'Centro de ayuda, contacto, términos y privacidad';

  @override
  String get settingsStarred => 'Mensajes destacados';

  @override
  String get settingsLinkedDevices => 'Dispositivos vinculados';

  @override
  String get settingsTwoStep => 'Verificación en dos pasos';

  @override
  String get settingsChangeNumber => 'Cambiar número';

  @override
  String get settingsExport => 'Solicitar info de la cuenta';

  @override
  String get settingsAppLock => 'Bloqueo de la app';

  @override
  String get settingsSignOut => 'Cerrar sesión';

  @override
  String get settingsDeleteAccount => 'Eliminar cuenta';

  @override
  String settingsVersion(String version) {
    return 'Versión $version';
  }

  @override
  String get languageSystem => 'Predeterminado del sistema';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageSpanish => 'Español';

  @override
  String get commonCancel => 'Cancelar';

  @override
  String get commonSave => 'Guardar';

  @override
  String get commonDone => 'Listo';

  @override
  String get commonRetry => 'Reintentar';

  @override
  String get commonOn => 'Activado';

  @override
  String get commonOff => 'Desactivado';

  @override
  String get commonSaveFailed => 'No se pudo guardar. Inténtalo de nuevo.';

  @override
  String get chatsTitle => 'Chats';

  @override
  String get chatsSearchHint => 'Buscar chats';

  @override
  String get chatsEmptyTitle => 'Aún no hay conversaciones';

  @override
  String get chatsEmptyBody => 'Envía un mensaje a un colega para verlo aquí.';

  @override
  String get chatsArchived => 'Archivados';

  @override
  String get chatsDraftPrefix => 'Borrador: ';

  @override
  String get threadMessageHint => 'Mensaje';

  @override
  String get threadTyping => 'escribiendo…';

  @override
  String get threadOnline => 'en línea';

  @override
  String get threadSearch => 'Buscar en el chat';

  @override
  String get threadReply => 'Responder';

  @override
  String get threadForward => 'Reenviar';

  @override
  String get threadCopy => 'Copiar';

  @override
  String get threadDelete => 'Eliminar';

  @override
  String get threadEdited => 'editado';

  @override
  String get threadMessageDeleted => 'Mensaje eliminado';

  @override
  String get appearanceTitle => 'Chats y apariencia';

  @override
  String get appearanceDisplay => 'Pantalla';

  @override
  String get appearanceTheme => 'Tema';

  @override
  String get appearanceThemeLight => 'Claro';

  @override
  String get appearanceThemeDark => 'Oscuro';

  @override
  String get appearanceThemeSystem => 'Sistema';

  @override
  String get appearanceFontSize => 'Tamaño de letra';

  @override
  String get appearanceFontSmall => 'Pequeño';

  @override
  String get appearanceFontMedium => 'Mediano';

  @override
  String get appearanceFontLarge => 'Grande';

  @override
  String get appearanceFontHint =>
      'También sigue el tamaño de texto del teléfono';

  @override
  String get appearancePreview => 'Mensajería segura que se adapta a tu día.';

  @override
  String get appearanceChatsSection => 'Chats';

  @override
  String get appearanceDefaultChatTheme => 'Color de chat predeterminado';

  @override
  String get appearanceDefaultWallpaper => 'Fondo predeterminado';

  @override
  String get appearanceWallpaperNone => 'Ninguno';

  @override
  String get appearanceWallpaperPhoto => 'Tu foto';

  @override
  String get appearanceEnterIsSend => 'Enter para enviar';

  @override
  String get appearanceEnterIsSendHint =>
      'La tecla Intro envía en lugar de añadir una línea';

  @override
  String get appearanceVoiceTranscript => 'Transcripción de notas de voz';

  @override
  String get appearanceVoiceTranscriptHint =>
      'Transcribe las notas de voz mientras grabas';

  @override
  String get appearanceKeepArchived => 'Mantener chats archivados';

  @override
  String get appearanceKeepArchivedHint =>
      'Los chats archivados siguen archivados al llegar un mensaje nuevo';

  @override
  String get chatThemeTitle => 'Color del chat';

  @override
  String get chatThemeDefault => 'Predeterminado';

  @override
  String get chatThemeDefaultHint => 'Usa tu color de chat predeterminado';

  @override
  String get chatThemeSent => 'Perfecto, nos vemos a las 3';

  @override
  String get chatThemeReceived => '¿Movemos la ronda a las 3?';

  @override
  String get chatThemeSaveFailed =>
      'No se pudo cambiar el color del chat. Inténtalo de nuevo.';

  @override
  String get wallpaperTitle => 'Fondo';

  @override
  String get wallpaperPatterns => 'Patrones';

  @override
  String get wallpaperSolids => 'Colores lisos';

  @override
  String get wallpaperPhoto => 'Elegir de fotos';

  @override
  String get wallpaperNone => 'Ninguno';

  @override
  String get wallpaperDim => 'Atenuar fondo en modo oscuro';

  @override
  String get wallpaperSaveFailed =>
      'No se pudo cambiar el fondo. Inténtalo de nuevo.';

  @override
  String get statusTitle => 'Estado';

  @override
  String get statusPresets => 'Predefinidos';

  @override
  String get statusCustom => 'Personalizado';

  @override
  String get statusCustomHint => '¿Qué deberían saber tus colegas?';

  @override
  String get statusClearAfter => 'Borrar después de';

  @override
  String get statusOneHour => '1 hora';

  @override
  String get statusEightHours => '8 horas';

  @override
  String get statusOneDay => '24 horas';

  @override
  String get statusNever => 'Nunca';

  @override
  String get statusSave => 'Guardar estado';

  @override
  String get statusClear => 'Borrar estado';

  @override
  String get statusNone => 'Sin estado';

  @override
  String get statusSaveFailed =>
      'No se pudo actualizar tu estado. Inténtalo de nuevo.';

  @override
  String get notifTitle => 'Notificaciones';

  @override
  String get notifMessages => 'Mensajes';

  @override
  String get notifGroups => 'Grupos';

  @override
  String get notifTone => 'Tono';

  @override
  String get notifVibrate => 'Vibración';

  @override
  String get notifVibrateDefault => 'Predeterminada';

  @override
  String get notifVibrateShort => 'Corta';

  @override
  String get notifVibrateLong => 'Larga';

  @override
  String get notifVibrateOff => 'Desactivada';

  @override
  String get notifVibrateIosFooter =>
      'La vibración sigue los ajustes de tu iPhone.';

  @override
  String get notifShowPreview => 'Mostrar vista previa';

  @override
  String get notifShowPreviewHint =>
      'Mostrar el texto del mensaje en los avisos';

  @override
  String get notifHighPriority => 'Prioridad alta';

  @override
  String get notifHighPriorityHint =>
      'Mostrar avisos en la parte superior de la pantalla';

  @override
  String get notifReactions => 'Reacciones';

  @override
  String get notifReactionNotifications => 'Notificaciones de reacciones';

  @override
  String get notifReactionNotificationsHint =>
      'Avisar cuando alguien reaccione a tu mensaje';

  @override
  String get notifInApp => 'En la app';

  @override
  String get notifConversationTones => 'Tonos de conversación';

  @override
  String get notifConversationTonesHint =>
      'Reproducir sonidos al enviar y recibir mensajes';

  @override
  String get notifHaptics => 'Vibración háptica';

  @override
  String get notifHapticsHint => 'Vibración ligera con los mensajes nuevos';

  @override
  String get notifReset => 'Restablecer ajustes de notificaciones';

  @override
  String get notifResetTitle => '¿Restablecer los ajustes de notificaciones?';

  @override
  String get notifResetBody =>
      'Todos los tonos, vibraciones y vistas previas vuelven a los valores predeterminados. Las notificaciones personalizadas de cada chat se conservan.';

  @override
  String get notifResetConfirm => 'Restablecer';

  @override
  String get notifResetDone => 'Ajustes de notificaciones restablecidos';

  @override
  String get toneTitle => 'Tono';

  @override
  String get toneDefault => 'Predeterminado';

  @override
  String get toneNone => 'Ninguno';

  @override
  String get toneHint => 'Toca un tono para escucharlo.';

  @override
  String get chatNotifTitle => 'Notificaciones personalizadas';

  @override
  String get chatNotifUseCustom => 'Usar notificaciones personalizadas';

  @override
  String get chatNotifUseCustomHint =>
      'Elige un tono y una vibración solo para este chat';

  @override
  String get chatNotifMute => 'Silenciar notificaciones';

  @override
  String get chatNotifMuted => 'Silenciado';

  @override
  String get chatNotifNotMuted => 'No silenciado';

  @override
  String get chatNotifUnmute => 'Activar sonido';

  @override
  String get appLockLockedTitle => 'Doqto está bloqueado';

  @override
  String get appLockLockedBody =>
      'Desbloquea con Face ID, Touch ID o tu código.';

  @override
  String get appLockUnlock => 'Desbloquear';

  @override
  String get appLockUnavailable =>
      'Configura primero un código o biometría en este teléfono.';

  @override
  String get appLockEnableReason =>
      'Confirma que eres tú para activar el bloqueo';

  @override
  String get appLockNotVerified =>
      'No se pudo verificar: el bloqueo sigue desactivado.';

  @override
  String get appLockFooter =>
      'Cuando está activo, Doqto pide Face ID, Touch ID o tu código al volver a la app. Seguirás viendo notificaciones.';

  @override
  String get appLockSwitch => 'Requerir desbloqueo';

  @override
  String get appLockSwitchHint => 'Face ID, Touch ID o código';

  @override
  String get appLockAfter => 'Bloquear tras';

  @override
  String get appLockImmediately => 'Inmediatamente';

  @override
  String get appLockOneMinute => '1 minuto';

  @override
  String get appLockFifteenMinutes => '15 minutos';

  @override
  String get appLockOneHour => '1 hora';

  @override
  String get devicesThisDevice => 'Este dispositivo';

  @override
  String get devicesOtherDevices => 'Otros dispositivos';

  @override
  String get devicesFooter =>
      'Cerrar la sesión de un dispositivo la termina de inmediato. Necesitará un código nuevo para volver a entrar.';

  @override
  String get devicesNone => 'No hay otros dispositivos con sesión iniciada.';

  @override
  String get devicesActiveNow => 'Activo ahora';

  @override
  String get devicesSignOut => 'Cerrar sesión';

  @override
  String devicesSignOutTitle(String device) {
    return '¿Cerrar sesión en $device?';
  }

  @override
  String get devicesSignOutBody =>
      'La sesión de ese dispositivo se cerrará de inmediato.';

  @override
  String get devicesSignOutOthers => 'Cerrar sesión en los demás dispositivos';

  @override
  String get devicesSignOutOthersBody =>
      'Se cerrará la sesión en todos los dispositivos excepto este.';

  @override
  String devicesSignedOutCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Sesión cerrada en $count dispositivos',
      one: 'Sesión cerrada en 1 dispositivo',
      zero: 'No había otros dispositivos',
    );
    return '$_temp0';
  }

  @override
  String get pinOffFooter =>
      'Añade un PIN de 6 dígitos que cada dispositivo nuevo deberá introducir tras el código SMS. Protege tu cuenta si alguien se apodera de tu número.';

  @override
  String get pinOnFooter =>
      'La verificación en dos pasos está activa. Los dispositivos nuevos deben introducir tu PIN tras el código SMS.';

  @override
  String get pinTurnOn => 'Activar';

  @override
  String get pinChange => 'Cambiar PIN';

  @override
  String get pinTurnOff => 'Desactivar';

  @override
  String get pinNew => 'PIN nuevo';

  @override
  String get pinConfirm => 'Confirmar PIN';

  @override
  String get pinCurrent => 'PIN actual';

  @override
  String get pinMismatch => 'Los PIN no coinciden.';

  @override
  String get pinEnabledToast => 'Verificación en dos pasos activada.';

  @override
  String get pinChangedToast => 'PIN cambiado.';

  @override
  String get pinDisabledToast => 'Verificación en dos pasos desactivada.';

  @override
  String get pinGateTitle => 'Introduce tu PIN';

  @override
  String get pinGateBody =>
      'Esta cuenta tiene verificación en dos pasos. Introduce el PIN de 6 dígitos que configuraste.';

  @override
  String get pinGateHint => 'PIN de 6 dígitos';

  @override
  String get pinGateContinue => 'Continuar';

  @override
  String get pinGateForgot => '¿Olvidaste el PIN?';

  @override
  String get pinGateForgotTitle => '¿Quitar tu PIN?';

  @override
  String get pinGateForgotBody =>
      'Por seguridad, el PIN se elimina a los 7 días. Si lo introduces antes, se cancela la eliminación.';

  @override
  String get pinGateForgotAction => 'Iniciar espera de 7 días';

  @override
  String pinGateResetPending(String date) {
    return 'Tu PIN se eliminará el $date. Introdúcelo antes para cancelar.';
  }

  @override
  String get changeNumberIntro =>
      'Tus chats, contactos y grupos pasan contigo al número nuevo.';

  @override
  String changeNumberIntroCurrent(String phone) {
    return 'Número actual: $phone. Tus chats, contactos y grupos pasan contigo al número nuevo.';
  }

  @override
  String get changeNumberSend => 'Enviar código';

  @override
  String changeNumberSentTo(String phone) {
    return 'Código enviado a $phone';
  }

  @override
  String get changeNumberCodeHint => 'Código de 6 dígitos';

  @override
  String get changeNumberVerify => 'Verificar';

  @override
  String get changeNumberEditNumber => 'Usar otro número';

  @override
  String changeNumberDone(String phone) {
    return 'Tu número ahora es $phone';
  }

  @override
  String get changeNumberFooter =>
      'El número nuevo no puede estar en otra cuenta de Doqto. El anterior deja de servir para iniciar sesión de inmediato.';

  @override
  String get helpSupportSection => 'Soporte';

  @override
  String get helpLegalSection => 'Legal';

  @override
  String get helpCentre => 'Centro de ayuda';

  @override
  String get helpContact => 'Contáctanos';

  @override
  String get helpTerms => 'Términos del servicio';

  @override
  String get helpPrivacy => 'Política de privacidad';

  @override
  String get helpHipaa => 'Aviso HIPAA';

  @override
  String get helpLicences => 'Licencias de código abierto';

  @override
  String get helpOpenFailed => 'No se pudo abrir el enlace.';

  @override
  String get languageFooter =>
      'Cambia solo el idioma de Doqto. Los mensajes nunca se traducen.';

  @override
  String get forceUpdateTitle => 'Actualiza Doqto';

  @override
  String get forceUpdateBody =>
      'Esta versión ya no es compatible. Actualiza para seguir enviando mensajes.';

  @override
  String get forceUpdateButton => 'Actualizar';

  @override
  String get storageTitle => 'Almacenamiento y datos';

  @override
  String get storageComingSoon =>
      'Almacenamiento y datos: llega con la actualización multimedia.';
}
