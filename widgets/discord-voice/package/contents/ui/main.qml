import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid

PlasmoidItem {
    id: root

    property string status: "bridge-down"
    property string channel: ""
    property string guild: ""
    property var users: []
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

    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    function refresh() {
        const request = new XMLHttpRequest();
        request.open("GET", "http://127.0.0.1:5617/state");
        request.onreadystatechange = () => {
            if (request.readyState !== XMLHttpRequest.DONE) {
                return;
            }
            if (request.status !== 200) {
                status = "bridge-down";
                users = [];
                return;
            }
            const state = JSON.parse(request.responseText);
            status = state.status;
            channel = state.channel;
            guild = state.guild;
            users = state.users;
        };
        request.send();
    }

    fullRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 12
        Layout.minimumHeight: Kirigami.Units.gridUnit * 3
        Layout.preferredWidth: Kirigami.Units.gridUnit * 16
        Layout.preferredHeight: Kirigami.Units.gridUnit * 18

        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: Math.min(parent.height, content.implicitHeight + Kirigami.Units.gridUnit * 1.5)
            radius: Kirigami.Units.gridUnit
            color: "#c8101114"
            border.color: "#14ffffff"
            border.width: 1
            clip: true
            opacity: root.inCall ? 1 : 0.55
            Behavior on opacity {
                NumberAnimation { duration: Kirigami.Units.longDuration }
            }

            ColumnLayout {
                id: content
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Kirigami.Units.gridUnit * 0.75
                spacing: Kirigami.Units.smallSpacing * 2

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing * 2

                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
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
                            font.pointSize: Kirigami.Theme.defaultFont.pointSize + (root.inCall ? 1 : 0)
                            font.weight: root.inCall ? Font.DemiBold : Font.Normal
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: root.inCall && root.guild !== ""
                            text: root.guild
                            color: "#99a0a8"
                            elide: Text.ElideRight
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                    }

                    Text {
                        visible: root.inCall
                        text: root.users.length
                        color: "#99a0a8"
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                }

                Repeater {
                    model: root.inCall ? root.users : []

                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing * 2

                        Item {
                            implicitWidth: Kirigami.Units.gridUnit * 1.75
                            implicitHeight: implicitWidth

                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 3
                                radius: width / 2
                                color: "#3a3d44"

                                Text {
                                    anchors.centerIn: parent
                                    text: modelData.name.charAt(0).toUpperCase()
                                    color: "#c4c9ce"
                                }

                                Kirigami.ShadowedImage {
                                    anchors.fill: parent
                                    source: modelData.avatar
                                    radius: width / 2
                                    color: "transparent"
                                    fillMode: Image.PreserveAspectCrop
                                }
                            }

                            Rectangle {
                                anchors.fill: parent
                                radius: width / 2
                                color: "transparent"
                                border.color: "#23a55a"
                                border.width: 2
                                opacity: modelData.speaking ? 1 : 0
                                Behavior on opacity {
                                    NumberAnimation { duration: Kirigami.Units.shortDuration }
                                }
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            text: modelData.name
                            color: modelData.speaking ? "#ffffff" : "#c4c9ce"
                            elide: Text.ElideRight
                        }

                        Image {
                            visible: modelData.muted || modelData.deafened
                            sourceSize.width: Kirigami.Units.iconSizes.small
                            sourceSize.height: Kirigami.Units.iconSizes.small
                            source: Qt.resolvedUrl("../icons/" + (modelData.deafened ? "deafened" : "muted") + ".svg")
                        }
                    }
                }
            }
        }
    }
}
