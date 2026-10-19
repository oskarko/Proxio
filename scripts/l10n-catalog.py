#!/usr/bin/env python3
"""Writes Sources/ProxioApp/Localization/{en,es,ru,fr}.lproj/Localizable.strings.
English text is the key. Fails if a key found in the sources has no translation (parity check)
or a translation has no matching key, or format specifiers differ between languages."""
import os, re, sys, importlib.util

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("extract", os.path.join(here, "extract-l10n-keys.py"))
extract = importlib.util.module_from_spec(spec); spec.loader.exec_module(extract)

# key: (es, ru, fr)
T = {
"Scripting…": ("Scripts…", "Скрипты…", "Scripts…"),
"Scripts can change matching requests and responses with JavaScript. Define onRequest(request) and/or onResponse(request, response) and return the object. Keep scripts short: a script that never returns blocks its request.": (
 "Los scripts pueden modificar con JavaScript las peticiones y respuestas coincidentes. Define onRequest(request) y/o onResponse(request, response) y devuelve el objeto. Mantén los scripts cortos: uno que nunca termina bloquea su petición.",
 "Скрипты на JavaScript могут изменять подходящие запросы и ответы. Определите onRequest(request) и/или onResponse(request, response) и верните объект. Пишите короткие скрипты: скрипт, который не завершается, блокирует свой запрос.",
 "Les scripts peuvent modifier en JavaScript les requêtes et réponses correspondantes. Définissez onRequest(request) et/ou onResponse(request, response) et renvoyez l’objet. Gardez les scripts courts : un script qui ne se termine jamais bloque sa requête."),
"No scripts": ("Sin scripts", "Нет скриптов", "Aucun script"),
"Select a script": ("Selecciona un script", "Выберите скрипт", "Sélectionnez un script"),
"Console": ("Consola", "Консоль", "Console"),
"No console output yet": ("Aún no hay salida de consola", "Вывода консоли пока нет", "Aucune sortie console pour l’instant"),
"New script": ("Nuevo script", "Новый скрипт", "Nouveau script"),
"Stopped": ("Detenido", "Остановлен", "Arrêté"),
"Could not save rules: %@": ("No se pudieron guardar las reglas: %@", "Не удалось сохранить правила: %@", "Impossible d’enregistrer les règles : %@"),
"Listening on 127.0.0.1:%lld": ("Escuchando en 127.0.0.1:%lld", "Прослушивание на 127.0.0.1:%lld", "À l’écoute sur 127.0.0.1:%lld"),
"HTTPS interception on": ("Interceptación HTTPS activada", "Перехват HTTPS включён", "Interception HTTPS activée"),
"Could not start: %@": ("No se pudo iniciar: %@", "Не удалось запустить: %@", "Démarrage impossible : %@"),
"Export failed: %@": ("Error al exportar: %@", "Ошибка экспорта: %@", "Échec de l’export : %@"),
"Move the CA key into your Keychain?": ("¿Mover la clave de la CA a tu llavero?", "Переместить ключ ЦС в вашу связку ключей?", "Déplacer la clé de l’AC dans votre trousseau ?"),
"Proxio found its CA private key as a plaintext file (ca-key.pem). It can be stored in your login keychain instead; the file is then overwritten and deleted.": (
 "Proxio encontró su clave privada de CA como archivo de texto plano (ca-key.pem). Puede guardarse en tu llavero de inicio de sesión; después el archivo se sobrescribe y se elimina.",
 "Proxio обнаружил закрытый ключ ЦС в виде обычного файла (ca-key.pem). Его можно хранить в связке ключей входа; после этого файл перезаписывается и удаляется.",
 "Proxio a trouvé sa clé privée d’AC dans un fichier en clair (ca-key.pem). Elle peut être stockée dans votre trousseau de session ; le fichier est alors écrasé puis supprimé."),
"Move to Keychain": ("Mover al llavero", "Переместить в связку ключей", "Déplacer dans le trousseau"),
"Trust the Proxio root certificate?": ("¿Confiar en el certificado raíz de Proxio?", "Доверять корневому сертификату Proxio?", "Faire confiance au certificat racine de Proxio ?"),
"Proxio will run:\\n\\n%@\\n\\nWhile it is trusted, anyone who can read the CA private key can impersonate any website to this Mac. macOS will ask for your password.": (
 "Proxio ejecutará:\\n\\n%@\\n\\nMientras sea de confianza, cualquiera que pueda leer la clave privada de la CA puede suplantar cualquier sitio web en este Mac. macOS pedirá tu contraseña.",
 "Proxio выполнит:\\n\\n%@\\n\\nПока сертификат является доверенным, любой, кто может прочитать закрытый ключ ЦС, сможет выдавать себя за любой сайт на этом Mac. macOS запросит ваш пароль.",
 "Proxio va exécuter :\\n\\n%@\\n\\nTant qu’il est approuvé, toute personne pouvant lire la clé privée de l’AC peut usurper n’importe quel site web sur ce Mac. macOS demandera votre mot de passe."),
"Install and Trust": ("Instalar y confiar", "Установить и доверять", "Installer et approuver"),
"CA install failed: %@": ("Error al instalar la CA: %@", "Не удалось установить ЦС: %@", "Échec de l’installation de l’AC : %@"),
"Remove the Proxio root certificate?": ("¿Eliminar el certificado raíz de Proxio?", "Удалить корневой сертификат Proxio?", "Supprimer le certificat racine de Proxio ?"),
"It will no longer be trusted and will be deleted from your login keychain.": ("Dejará de ser de confianza y se eliminará de tu llavero de inicio de sesión.", "Он перестанет быть доверенным и будет удалён из вашей связки ключей входа.", "Il ne sera plus approuvé et sera supprimé de votre trousseau de session."),
"Remove": ("Eliminar", "Удалить", "Supprimer"),
"CA removal failed: %@": ("Error al eliminar la CA: %@", "Не удалось удалить ЦС: %@", "Échec de la suppression de l’AC : %@"),
"Route %@ traffic through Proxio?": ("¿Dirigir el tráfico de %@ por Proxio?", "Направлять трафик %@ через Proxio?", "Faire passer le trafic de %@ par Proxio ?"),
"The HTTP and HTTPS proxy of \\\"%@\\\" will be set to 127.0.0.1:%lld. Your current settings are saved and restored when you turn this off or stop the proxy.": (
 "El proxy HTTP y HTTPS de «%@» se establecerá en 127.0.0.1:%lld. Tus ajustes actuales se guardan y se restauran al desactivarlo o detener el proxy.",
 "HTTP- и HTTPS-прокси для «%@» будет установлен на 127.0.0.1:%lld. Текущие настройки сохраняются и восстанавливаются при выключении или остановке прокси.",
 "Le proxy HTTP et HTTPS de « %@ » sera défini sur 127.0.0.1:%lld. Vos réglages actuels sont enregistrés puis rétablis lorsque vous le désactivez ou arrêtez le proxy."),
"Enable": ("Activar", "Включить", "Activer"),
"System proxy change failed: %@": ("Error al cambiar el proxy del sistema: %@", "Не удалось изменить системный прокси: %@", "Échec de la modification du proxy système : %@"),
"Cancel": ("Cancelar", "Отмена", "Annuler"),
"Breakpoints pause matching traffic so you can edit it before it continues. Only works while the proxy is running; HTTPS needs interception on.": (
 "Los puntos de interrupción pausan el tráfico coincidente para que puedas editarlo antes de que continúe. Solo funcionan con el proxy en marcha; HTTPS requiere la interceptación activada.",
 "Точки останова приостанавливают подходящий трафик, чтобы вы могли изменить его перед продолжением. Работают только при запущенном прокси; для HTTPS нужен включённый перехват.",
 "Les points d’arrêt mettent en pause le trafic correspondant pour que vous puissiez le modifier avant qu’il continue. Ils ne fonctionnent que si le proxy est actif ; HTTPS nécessite l’interception."),
"Any": ("Cualquiera", "Любой", "Tous"),
"host/path pattern, * allowed": ("patrón host/ruta, se permite *", "шаблон host/путь, допускается *", "motif hôte/chemin, * autorisé"),
"Req": ("Pet.", "Запр.", "Req."),
"Res": ("Resp.", "Отв.", "Rép."),
"No breakpoints": ("Sin puntos de interrupción", "Нет точек останова", "Aucun point d’arrêt"),
"Add": ("Añadir", "Добавить", "Ajouter"),
"Done": ("Hecho", "Готово", "Terminé"),
"Method": ("Método", "Метод", "Méthode"),
"URL": ("URL", "URL", "URL"),
"Status": ("Estado", "Статус", "Statut"),
"Reason": ("Motivo", "Причина", "Motif"),
"Headers (Name: value, one per line)": ("Cabeceras (Nombre: valor, una por línea)", "Заголовки (Имя: значение, по одному в строке)", "En-têtes (Nom : valeur, un par ligne)"),
"%lld paused": ("%lld en pausa", "Приостановлено: %lld", "%lld en pause"),
"Cancel Request": ("Cancelar petición", "Отменить запрос", "Annuler la requête"),
"Execute": ("Ejecutar", "Выполнить", "Exécuter"),
"Body is binary (%@) and is kept unchanged": ("El cuerpo es binario (%@) y se mantiene sin cambios", "Тело двоичное (%@) и остаётся без изменений", "Le corps est binaire (%@) et reste inchangé"),
"Body": ("Cuerpo", "Тело", "Corps"),
"The URL is not valid": ("La URL no es válida", "Недопустимый URL", "L’URL n’est pas valide"),
"Status must be between 100 and 599": ("El estado debe estar entre 100 y 599", "Статус должен быть от 100 до 599", "Le statut doit être compris entre 100 et 599"),
"Request paused": ("Petición en pausa", "Запрос приостановлен", "Requête en pause"),
"Response paused": ("Respuesta en pausa", "Ответ приостановлен", "Réponse en pause"),
"Compose": ("Redactar", "Составить", "Composer"),
"Send %lld×": ("Enviar %lld×", "Отправить %lld×", "Envoyer %lld×"),
"Send": ("Enviar", "Отправить", "Envoyer"),
"Body is binary (%@) and is sent unchanged": ("El cuerpo es binario (%@) y se envía sin cambios", "Тело двоичное (%@) и отправляется без изменений", "Le corps est binaire (%@) et est envoyé inchangé"),
"Enter a full http:// or https:// URL": ("Introduce una URL completa http:// o https://", "Введите полный URL http:// или https://", "Saisissez une URL complète http:// ou https://"),
"All Traffic": ("Todo el tráfico", "Весь трафик", "Tout le trafic"),
"Domains": ("Dominios", "Домены", "Domaines"),
"Proxio": ("Proxio", "Proxio", "Proxio"),
"%lld requests": ("%lld peticiones", "Запросов: %lld", "%lld requêtes"),
"Code": ("Código", "Код", "Code"),
"Size": ("Tamaño", "Размер", "Taille"),
"Time": ("Tiempo", "Время", "Durée"),
"Compare": ("Comparar", "Сравнить", "Comparer"),
"Copy as cURL": ("Copiar como cURL", "Копировать как cURL", "Copier en cURL"),
"Repeat": ("Repetir", "Повторить", "Rejouer"),
"Edit and Repeat…": ("Editar y repetir…", "Изменить и повторить…", "Modifier et rejouer…"),
"Map Local with This Response": ("Map Local con esta respuesta", "Map Local с этим ответом", "Map Local avec cette réponse"),
"Add Breakpoint for %@": ("Añadir punto de interrupción para %@", "Добавить точку останова для %@", "Ajouter un point d’arrêt pour %@"),
"2 requests selected": ("2 peticiones seleccionadas", "Выбрано 2 запроса", "2 requêtes sélectionnées"),
"Select a request": ("Selecciona una petición", "Выберите запрос", "Sélectionnez une requête"),
"Clear": ("Limpiar", "Очистить", "Effacer"),
"Breakpoints": ("Puntos de interrupción", "Точки останова", "Points d’arrêt"),
"Map Local / Remote": ("Map Local / Remote", "Map Local / Remote", "Map Local / Remote"),
"Settings": ("Ajustes", "Настройки", "Réglages"),
"System proxy on": ("Proxy del sistema activado", "Системный прокси включён", "Proxy système activé"),
"Certificate trusted": ("Certificado de confianza", "Сертификат доверенный", "Certificat approuvé"),
"Proxy": ("Proxy", "Прокси", "Proxy"),
"Port": ("Puerto", "Порт", "Port"),
"Intercept HTTPS (decrypt traffic)": ("Interceptar HTTPS (descifrar tráfico)", "Перехватывать HTTPS (расшифровка трафика)", "Intercepter HTTPS (déchiffrer le trafic)"),
"Certificate": ("Certificado", "Сертификат", "Certificat"),
"Root certificate": ("Certificado raíz", "Корневой сертификат", "Certificat racine"),
"Install and Trust…": ("Instalar y confiar…", "Установить и доверять…", "Installer et approuver…"),
"Remove…": ("Eliminar…", "Удалить…", "Supprimer…"),
"Nothing is installed until you confirm the exact command.": ("No se instala nada hasta que confirmes el comando exacto.", "Ничего не устанавливается, пока вы не подтвердите точную команду.", "Rien n’est installé tant que vous n’avez pas confirmé la commande exacte."),
"System": ("Sistema", "Система", "Système"),
"Use as system proxy": ("Usar como proxy del sistema", "Использовать как системный прокси", "Utiliser comme proxy système"),
"SSL proxying": ("Proxy SSL", "SSL-проксирование", "Proxy SSL"),
"One pattern per line: host, *.host, or host:port. Exclusions win. With no inclusions every host is intercepted.": (
 "Un patrón por línea: host, *.host o host:puerto. Las exclusiones tienen prioridad. Sin inclusiones se intercepta cualquier host.",
 "Один шаблон в строке: host, *.host или host:порт. Исключения имеют приоритет. Без включений перехватываются все хосты.",
 "Un motif par ligne : hôte, *.hôte ou hôte:port. Les exclusions l’emportent. Sans inclusion, tous les hôtes sont interceptés."),
"Include…": ("Incluir…", "Включить…", "Inclure…"),
"Exclude… e.g. *.apple.com": ("Excluir… p. ej. *.apple.com", "Исключить… напр. *.apple.com", "Exclure… p. ex. *.apple.com"),
"Clear session": ("Limpiar sesión", "Очистить сеанс", "Effacer la session"),
"Proxy settings": ("Ajustes del proxy", "Настройки прокси", "Réglages du proxy"),
"Select two requests to compare them": ("Selecciona dos peticiones para compararlas", "Выберите два запроса для сравнения", "Sélectionnez deux requêtes à comparer"),
"Filter by URL, method, status or type": ("Filtrar por URL, método, estado o tipo", "Фильтр по URL, методу, статусу или типу", "Filtrer par URL, méthode, statut ou type"),
"All": ("Todo", "Все", "Tout"),
"HTTPS": ("HTTPS", "HTTPS", "HTTPS"),
"WebSocket": ("WebSocket", "WebSocket", "WebSocket"),
"Errors": ("Errores", "Ошибки", "Erreurs"),
"Stop": ("Detener", "Остановить", "Arrêter"),
"Start": ("Iniciar", "Запустить", "Démarrer"),
"Stop the proxy": ("Detener el proxy", "Остановить прокси", "Arrêter le proxy"),
"Start the proxy": ("Iniciar el proxy", "Запустить прокси", "Démarrer le proxy"),
"127.0.0.1:%lld": ("127.0.0.1:%lld", "127.0.0.1:%lld", "127.0.0.1:%lld"),
"Not recording": ("Sin grabar", "Запись остановлена", "Enregistrement arrêté"),
"Trusted on this Mac": ("De confianza en este Mac", "Доверенный на этом Mac", "Approuvé sur ce Mac"),
"Not trusted": ("Sin confianza", "Не доверенный", "Non approuvé"),
"Only changes": ("Solo cambios", "Только изменения", "Modifications seules"),
"Neither request has a response": ("Ninguna petición tiene respuesta", "Ни у одного запроса нет ответа", "Aucune requête n’a de réponse"),
"→ %lld": ("→ %lld", "→ %lld", "→ %lld"),
"(empty)": ("(vacío)", "(пусто)", "(vide)"),
"No differences": ("Sin diferencias", "Различий нет", "Aucune différence"),
"⋯ 1 unchanged line": ("⋯ 1 línea sin cambios", "⋯ 1 строка без изменений", "⋯ 1 ligne inchangée"),
"⋯ %lld unchanged lines": ("⋯ %lld líneas sin cambios", "⋯ Строк без изменений: %lld", "⋯ %lld lignes inchangées"),
"Identical": ("Idénticas", "Идентичны", "Identiques"),
"Different": ("Diferentes", "Различаются", "Différentes"),
"Start line": ("Línea inicial", "Начальная строка", "Ligne de début"),
"Headers": ("Cabeceras", "Заголовки", "En-têtes"),
"No response yet": ("Aún sin respuesta", "Ответа пока нет", "Pas encore de réponse"),
"Name": ("Nombre", "Имя", "Nom"),
"Value": ("Valor", "Значение", "Valeur"),
"Empty body": ("Cuerpo vacío", "Пустое тело", "Corps vide"),
"Type": ("Tipo", "Тип", "Type"),
"Data": ("Datos", "Данные", "Données"),
"Select a message": ("Selecciona un mensaje", "Выберите сообщение", "Sélectionnez un message"),
"decoded": ("decodificado", "декодировано", "décodé"),
"Text": ("Texto", "Текст", "Texte"),
"Binary": ("Binario", "Двоичные", "Binaire"),
"Close": ("Cierre", "Закрытие", "Fermeture"),
"Query": ("Consulta", "Запрос", "Paramètres"),
"Raw": ("Sin procesar", "Исходный", "Brut"),
"Messages": ("Mensajes", "Сообщения", "Messages"),
"Pretty": ("Formateado", "Форматированный", "Formaté"),
"Hex": ("Hex", "Hex", "Hex"),
"Ping": ("Ping", "Ping", "Ping"),
"Pong": ("Pong", "Pong", "Pong"),
"Request": ("Petición", "Запрос", "Requête"),
"Response": ("Respuesta", "Ответ", "Réponse"),
"Map Local": ("Map Local", "Map Local", "Map Local"),
"Map Remote": ("Map Remote", "Map Remote", "Map Remote"),
"No Map Local rules": ("Sin reglas Map Local", "Нет правил Map Local", "Aucune règle Map Local"),
"Select a rule": ("Selecciona una regla", "Выберите правило", "Sélectionnez une règle"),
"host/path pattern": ("patrón host/ruta", "шаблон host/путь", "motif hôte/chemin"),
"scheme": ("esquema", "схема", "schéma"),
"host": ("host", "хост", "hôte"),
"port": ("puerto", "порт", "port"),
"path": ("ruta", "путь", "chemin"),
"No Map Remote rules": ("Sin reglas Map Remote", "Нет правил Map Remote", "Aucune règle Map Remote"),
"URL pattern": ("Patrón de URL", "Шаблон URL", "Motif d’URL"),
"Inline": ("En línea", "Встроенный", "En ligne"),
"File": ("Archivo", "Файл", "Fichier"),
"Path": ("Ruta", "Путь", "Chemin"),
"Choose…": ("Elegir…", "Выбрать…", "Choisir…"),
"Headers (Name: value)": ("Cabeceras (Nombre: valor)", "Заголовки (Имя: значение)", "En-têtes (Nom : valeur)"),
"Answer matching requests with a file or text, without contacting the server.": ("Responde a las peticiones coincidentes con un archivo o texto, sin contactar con el servidor.", "Отвечает на подходящие запросы файлом или текстом, не обращаясь к серверу.", "Répond aux requêtes correspondantes avec un fichier ou du texte, sans contacter le serveur."),
"Send matching requests to a different scheme, host, port or path. Empty fields keep the original.": ("Envía las peticiones coincidentes a otro esquema, host, puerto o ruta. Los campos vacíos conservan el original.", "Перенаправляет подходящие запросы на другую схему, хост, порт или путь. Пустые поля сохраняют исходное значение.", "Envoie les requêtes correspondantes vers un autre schéma, hôte, port ou chemin. Les champs vides conservent la valeur d’origine."),
"(any)": ("(cualquiera)", "(любой)", "(tous)"),
"inline": ("en línea", "встроенный", "en ligne"),
"Settings…": ("Ajustes…", "Настройки…", "Réglages…"),
"Export as HAR…": ("Exportar como HAR…", "Экспортировать как HAR…", "Exporter en HAR…"),
"Clear Session": ("Limpiar sesión", "Очистить сеанс", "Effacer la session"),
"Tools": ("Herramientas", "Инструменты", "Outils"),
"Breakpoints…": ("Puntos de interrupción…", "Точки останова…", "Points d’arrêt…"),
"Map Local / Remote…": ("Map Local / Remote…", "Map Local / Remote…", "Map Local / Remote…"),
"Compose…": ("Redactar…", "Составить…", "Composer…"),
"Repeat Selected": ("Repetir selección", "Повторить выбранное", "Rejouer la sélection"),
"Compare Selected": ("Comparar selección", "Сравнить выбранное", "Comparer la sélection"),
"Show Certificate in Finder": ("Mostrar certificado en el Finder", "Показать сертификат в Finder", "Afficher le certificat dans le Finder"),
"Use as System Proxy": ("Usar como proxy del sistema", "Использовать как системный прокси", "Utiliser comme proxy système"),
"Intercept HTTPS": ("Interceptar HTTPS", "Перехватывать HTTPS", "Intercepter HTTPS"),
"Proxy Settings…": ("Ajustes del proxy…", "Настройки прокси…", "Réglages du proxy…"),
"Proxio on GitHub": ("Proxio en GitHub", "Proxio на GitHub", "Proxio sur GitHub"),
"Stop Recording": ("Detener grabación", "Остановить запись", "Arrêter l’enregistrement"),
"Start Recording": ("Iniciar grabación", "Начать запись", "Démarrer l’enregistrement"),
}
# Extracted but not user-facing text.
IGNORE = {"lock.fill", "globe", "stop.circle.fill", "record.circle", "pause.circle", "pause.circle.fill",
          "arrow.up.circle.fill", "arrow.down.circle.fill", "inline", "%@ ms"}

def specs(s): return sorted(re.findall(r"%(?:lld|@)", s))

def main():
    found = {k for k in extract.keys() if k not in IGNORE or k in T}
    found -= {k for k in IGNORE if k not in T}
    missing = sorted(found - T.keys())
    extra = sorted(T.keys() - found)
    bad = [k for k, v in T.items() if any(specs(x) != specs(k) for x in v)]
    if "--check" in sys.argv or missing or bad:
        for k in missing: print("MISSING translation:", k)
        for k in bad: print("FORMAT mismatch:", k)
        for k in extra: print("note: unused translation:", k)
        if missing or bad: sys.exit(1)
        if "--check" in sys.argv: return
    root = os.path.join(here, "..", "Sources", "ProxioApp", "Localization")
    for idx, lang in enumerate(["en", "es", "ru", "fr"]):
        d = os.path.join(root, f"{lang}.lproj"); os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8") as f:
            f.write("/* Generated by scripts/l10n-catalog.py — edit the table there. */\n")
            for k in sorted(T):
                v = k if lang == "en" else T[k][idx - 1]
                f.write(f'"{k}" = "{v}";\n')
    print(f"wrote {len(T)} keys x 4 languages")

main()
