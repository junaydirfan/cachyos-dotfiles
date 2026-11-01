import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Effects
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid

PlasmoidItem {
    id: root

    readonly property string bridge: "http://127.0.0.1:5617"
    property string status: "bridge-down"
    property string channel: ""
    property string guild: ""
    property string link: ""
    property bool selfMuted: false
    property bool selfDeafened: false
    property int version: -1
    property string selectedId: ""
    property Item wallpaper: null
    readonly property bool inCall: status === "in-call"
    readonly property string message: ({
        "idle": "Not in a voice channel",
        "offline": "Discord isn't running",
        "authorizing": "Approve the request in Discord",
        "auth-error": "Sign-in failed, see the Redirects step in setup.sh",
        "no-config": "Run widgets/discord-voice/setup.sh",
        "bridge-down": "Voice bridge isn't running"
    })[status] ?? ""

    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    preferredRepresentation: fullRepresentation

    // Delegates stay alive between updates, so a speaking ring can fade instead of redrawing.
    ListModel {
        id: people
    }

    Timer {
        id: retry
        interval: 2000
        onTriggered: root.poll()
    }

    Component.onCompleted: {
        poll();
        for (let item = root.parent; item; item = item.parent) {
            if (item.wallpaper) {
                wallpaper = item.wallpaper;
                break;
            }
        }
    }

    // The bridge holds this request open until something changes.
    function poll() {
        const request = new XMLHttpRequest();
        request.open("GET", `${bridge}/state?since=${version}`);
        request.onreadystatechange = () => {
            if (request.readyState !== XMLHttpRequest.DONE) {
                return;
            }
            if (request.status !== 200) {
                status = "bridge-down";
                version = -1;
                people.clear();
                retry.start();
                return;
            }
            apply(JSON.parse(request.responseText));
            poll();
        };
        request.send();
    }

    function apply(state) {
        version = state.version;
        status = state.status;
        channel = state.channel;
        guild = state.guild;
        link = state.link;
        selfMuted = state.selfMuted;
        selfDeafened = state.selfDeafened;

        const ids = state.users.map(user => user.id);
        for (let i = people.count - 1; i >= 0; i--) {
            if (!ids.includes(people.get(i).uid)) {
                people.remove(i);
            }
        }
        for (const user of state.users) {
            const row = {
                uid: user.id,
                name: user.name,
                avatar: user.avatar,
                muted: user.muted,
                deafened: user.deafened,
                speaking: user.speaking,
                isSelf: user.self,
                volume: user.volume,
                localMute: user.localMute,
            };
            let index = -1;
            for (let i = 0; i < people.count; i++) {
                if (people.get(i).uid === user.id) {
                    index = i;
                }
            }
            if (index < 0) {
                people.append(row);
            } else {
                people.set(index, row);
            }
        }
        if (!ids.includes(selectedId)) {
            selectedId = "";
        }
    }

    function act(action) {
        const request = new XMLHttpRequest();
        request.open("POST", `${bridge}/action`);
        request.setRequestHeader("Content-Type", "application/json");
        request.setRequestHeader("X-Voice-Widget", "1");
        request.send(JSON.stringify(action));
    }

    function selected() {
        for (let i = 0; i < people.count; i++) {
            if (people.get(i).uid === selectedId) {
                return people.get(i);
            }
        }
        return null;
    }

    component RoundButton: Rectangle {
        id: button
        property string icon
        property bool active: false
        property bool danger: false
        property string tip
        signal clicked

        implicitWidth: Kirigami.Units.gridUnit * 2
        implicitHeight: implicitWidth
        radius: width / 2
        color: active || danger ? (hover.hovered ? "#66f23f43" : "#40f23f43")
                                : (hover.hovered ? "#2effffff" : "#14ffffff")

        Behavior on color {
            ColorAnimation { duration: Kirigami.Units.shortDuration }
        }

        Image {
            anchors.centerIn: parent
            sourceSize.width: Kirigami.Units.iconSizes.small
            sourceSize.height: Kirigami.Units.iconSizes.small
            source: Qt.resolvedUrl(`../icons/${button.icon}.svg`)
        }

        HoverHandler {
            id: hover
            cursorShape: Qt.PointingHandCursor
        }

        TapHandler {
            onTapped: button.clicked()
        }

        QQC2.ToolTip.visible: hover.hovered
        QQC2.ToolTip.text: tip
        QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
    }

    fullRepresentation: Item {
        id: view

        Layout.minimumWidth: Kirigami.Units.gridUnit * 14
        Layout.minimumHeight: Kirigami.Units.gridUnit * 3
        Layout.preferredWidth: Kirigami.Units.gridUnit * 18
        Layout.preferredHeight: Kirigami.Units.gridUnit * 20

        readonly property int padding: Kirigami.Units.gridUnit * 0.75
        // Few people get large tiles, and a full channel stays at two rows.
        readonly property int columns: people.count <= 2 ? Math.max(people.count, 1)
                                     : people.count === 3 ? 3
                                     : people.count <= 8 ? 4 : 5
        readonly property real tileWidth: (card.width - padding * 2 - (columns - 1) * grid.columnSpacing) / columns
        readonly property real avatarSize: Math.min(tileWidth - Kirigami.Units.smallSpacing * 2,
                                                    Kirigami.Units.gridUnit * (people.count <= 3 ? 3.5 : 2.75))

        Rectangle {
            id: mask
            anchors.fill: card
            radius: card.radius
            visible: false
            layer.enabled: true
        }

        ShaderEffectSource {
            id: backdrop
            anchors.fill: card
            visible: false
            live: true
            sourceItem: root.wallpaper
        }

        Timer {
            // A desktop widget can be dragged without its own position changing.
            interval: 1000
            running: root.wallpaper !== null
            repeat: true
            triggeredOnStart: true
            onTriggered: {
                const origin = card.mapToItem(root.wallpaper, 0, 0);
                backdrop.sourceRect = Qt.rect(origin.x, origin.y, card.width, card.height);
            }
        }

        MultiEffect {
            anchors.fill: card
            source: backdrop
            visible: root.wallpaper !== null
            autoPaddingEnabled: false
            blurEnabled: true
            blur: 1
            blurMax: 48
            maskEnabled: true
            maskSource: mask
        }

        Rectangle {
            id: card
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: Math.min(parent.height, content.implicitHeight + view.padding * 2)
            radius: Kirigami.Units.gridUnit
            // The same near-black as the dock, more solid if the blur isn't available.
            color: root.wallpaper ? "#b80c0d10" : "#e60c0d10"
            border.color: "#1affffff"
            border.width: 1
            clip: true

            Behavior on height {
                NumberAnimation { duration: Kirigami.Units.shortDuration; easing.type: Easing.OutCubic }
            }

            ColumnLayout {
                id: content
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: view.padding
                spacing: Kirigami.Units.smallSpacing * 2

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing * 2

                    Rectangle {
                        implicitWidth: 8
                        implicitHeight: 8
                        radius: 4
                        color: root.inCall ? "#23a55a" : "#80848e"
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        Text {
                            Layout.fillWidth: true
                            text: root.inCall ? root.channel : root.message
                            color: "#f2f3f5"
                            elide: Text.ElideRight
                            font.weight: root.inCall ? Font.DemiBold : Font.Normal
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: root.inCall && root.guild !== ""
                            text: root.guild
                            color: "#99a0a8"
                            elide: Text.ElideRight
                            font: Kirigami.Theme.smallFont
                        }

                        HoverHandler {
                            enabled: root.inCall
                            cursorShape: Qt.PointingHandCursor
                        }

                        TapHandler {
                            enabled: root.inCall
                            onTapped: Qt.openUrlExternally(root.link)
                        }
                    }

                    Text {
                        visible: root.inCall
                        text: people.count
                        color: "#99a0a8"
                        font: Kirigami.Theme.smallFont
                    }
                }

                GridLayout {
                    id: grid
                    Layout.fillWidth: true
                    visible: root.inCall
                    columns: view.columns
                    columnSpacing: Kirigami.Units.smallSpacing
                    rowSpacing: Kirigami.Units.smallSpacing

                    Repeater {
                        model: people

                        delegate: Item {
                            id: tile
                            required property string uid
                            required property string name
                            required property string avatar
                            required property bool muted
                            required property bool deafened
                            required property bool speaking
                            required property bool isSelf
                            required property bool localMute
                            readonly property bool picked: root.selectedId === uid

                            Layout.preferredWidth: view.tileWidth
                            Layout.preferredHeight: picture.height + label.implicitHeight + Kirigami.Units.smallSpacing * 3

                            Rectangle {
                                anchors.fill: parent
                                radius: Kirigami.Units.smallSpacing * 2
                                color: tile.picked ? "#24ffffff" : (tileHover.hovered && !tile.isSelf ? "#12ffffff" : "transparent")
                            }

                            Item {
                                id: picture
                                anchors.top: parent.top
                                anchors.topMargin: Kirigami.Units.smallSpacing
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: view.avatarSize
                                height: width

                                Rectangle {
                                    anchors.fill: parent
                                    anchors.margins: 3
                                    radius: width / 2
                                    color: "#3a3d44"

                                    Text {
                                        anchors.centerIn: parent
                                        text: tile.name.charAt(0).toUpperCase()
                                        color: "#c4c9ce"
                                    }

                                    Kirigami.ShadowedImage {
                                        anchors.fill: parent
                                        source: tile.avatar
                                        radius: width / 2
                                        color: "transparent"
                                        fillMode: Image.PreserveAspectCrop
                                        opacity: tile.localMute ? 0.4 : 1
                                    }
                                }

                                Rectangle {
                                    anchors.fill: parent
                                    radius: width / 2
                                    color: "transparent"
                                    border.color: "#23a55a"
                                    border.width: 2.5
                                    opacity: tile.speaking ? 1 : 0
                                    // On at once, off slowly, so short bursts of speech stay readable.
                                    Behavior on opacity {
                                        enabled: !tile.speaking
                                        NumberAnimation { duration: Kirigami.Units.longDuration * 2 }
                                    }
                                }

                                Rectangle {
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    width: Kirigami.Units.gridUnit
                                    height: width
                                    radius: width / 2
                                    color: "#e60c0d10"
                                    visible: tile.muted || tile.deafened || tile.localMute

                                    Image {
                                        anchors.centerIn: parent
                                        sourceSize.width: parent.width * 0.7
                                        sourceSize.height: parent.width * 0.7
                                        source: Qt.resolvedUrl(`../icons/${tile.deafened ? "deafened" : "muted"}.svg`)
                                    }
                                }
                            }

                            Text {
                                id: label
                                anchors.top: picture.bottom
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.margins: 2
                                horizontalAlignment: Text.AlignHCenter
                                text: tile.name
                                color: tile.speaking ? "#ffffff" : "#c4c9ce"
                                elide: Text.ElideRight
                                font: Kirigami.Theme.smallFont
                            }

                            HoverHandler {
                                id: tileHover
                                cursorShape: tile.isSelf ? Qt.ArrowCursor : Qt.PointingHandCursor
                            }

                            TapHandler {
                                enabled: !tile.isSelf
                                onTapped: root.selectedId = tile.picked ? "" : tile.uid
                            }

                            QQC2.ToolTip.visible: tileHover.hovered
                            QQC2.ToolTip.text: tile.name
                            QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                        }
                    }
                }

                RowLayout {
                    id: listener
                    Layout.fillWidth: true
                    visible: root.selectedId !== ""
                    spacing: Kirigami.Units.smallSpacing * 2

                    readonly property var person: root.version, root.selected()

                    RoundButton {
                        icon: listener.person?.localMute ? "muted" : "volume"
                        active: listener.person?.localMute ?? false
                        tip: active ? "Unmute for me" : "Mute for me"
                        onClicked: root.act({
                            action: "user-mute",
                            user_id: root.selectedId,
                            mute: !listener.person.localMute,
                        })
                    }

                    QQC2.Slider {
                        id: volume
                        Layout.fillWidth: true
                        from: 0
                        to: 200
                        stepSize: 5
                        value: listener.person?.volume ?? 100
                        onMoved: send.restart()

                        Timer {
                            id: send
                            interval: 120
                            onTriggered: root.act({
                                action: "user-volume",
                                user_id: root.selectedId,
                                volume: volume.value,
                            })
                        }
                    }

                    Text {
                        text: `${Math.round(volume.value)}%`
                        color: "#c4c9ce"
                        font: Kirigami.Theme.smallFont
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    visible: root.inCall
                    spacing: Kirigami.Units.smallSpacing * 2

                    Item {
                        Layout.fillWidth: true
                    }

                    RoundButton {
                        icon: root.selfMuted ? "muted" : "mic"
                        active: root.selfMuted
                        tip: root.selfMuted ? "Unmute" : "Mute"
                        onClicked: root.act({ action: "toggle-mute" })
                    }

                    RoundButton {
                        icon: root.selfDeafened ? "deafened" : "headphones"
                        active: root.selfDeafened
                        tip: root.selfDeafened ? "Undeafen" : "Deafen"
                        onClicked: root.act({ action: "toggle-deafen" })
                    }

                    RoundButton {
                        icon: "leave"
                        danger: true
                        tip: "Leave the channel"
                        onClicked: root.act({ action: "leave" })
                    }

                    Item {
                        Layout.fillWidth: true
                    }
                }
            }
        }
    }
}
