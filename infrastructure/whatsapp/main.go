package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	_ "github.com/mattn/go-sqlite3"
	"github.com/skip2/go-qrcode"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
)

type BridgeEvent struct {
	Type     string `json:"type"`
	ChatID   string `json:"chat_id,omitempty"`
	SenderID string `json:"sender_id,omitempty"`
	Text     string `json:"text,omitempty"`
	IsGroup  bool   `json:"is_group,omitempty"`
	QR       string `json:"qr,omitempty"`
	ASCII    string `json:"ascii,omitempty"`
}

type BridgeAction struct {
	Action string `json:"action"`
	ChatID string `json:"chat_id"`
	Text   string `json:"text"`
}

func main() {
	dbLog := waLog.Stdout("Database", "ERROR", true)
	// New whatsmeow API requires context for New
	container, err := sqlstore.New(context.Background(), "sqlite3", "file:sessions/whatsapp/whatsmeow.db?_foreign_keys=on", dbLog)
	if err != nil {
		panic(err)
	}
	deviceStore, err := container.GetFirstDevice(context.Background())
	if err != nil {
		panic(err)
	}
	clientLog := waLog.Stdout("Client", "ERROR", true)
	client := whatsmeow.NewClient(deviceStore, clientLog)

	client.AddEventHandler(func(evt interface{}) {
		switch v := evt.(type) {
		case *events.Message:
			handleMessage(v)
		case *events.Connected:
			sendEvent(BridgeEvent{Type: "ready"})
		}
	})

	if client.Store.ID == nil {
		qrChan, _ := client.GetQRChannel(context.Background())
		err = client.Connect()
		if err != nil {
			panic(err)
		}
		for evt := range qrChan {
			if evt.Event == "code" {
				q, _ := qrcode.New(evt.Code, qrcode.Medium)
				ascii := q.ToSmallString(false)
				sendEvent(BridgeEvent{Type: "qr", QR: evt.Code, ASCII: ascii})
			}
		}
	} else {
		err = client.Connect()
		if err != nil {
			panic(err)
		}
	}

	// Listen for actions from Stdio
	go func() {
		scanner := bufio.NewScanner(os.Stdin)
		for scanner.Scan() {
			var action BridgeAction
			if err := json.Unmarshal(scanner.Bytes(), &action); err == nil {
				if action.Action == "send_message" {
					jid, _ := types.ParseJID(action.ChatID)
					msg := &waE2E.Message{Conversation: proto.String(action.Text)}
					client.SendMessage(context.Background(), jid, msg)
				}
			}
		}
	}()

	c := make(chan os.Signal, 1)
	signal.Notify(c, os.Interrupt, syscall.SIGTERM)
	<-c

	client.Disconnect()
}

func handleMessage(evt *events.Message) {
	if evt.Info.IsFromMe {
		return
	}

	text := ""
	if evt.Message.GetConversation() != "" {
		text = evt.Message.GetConversation()
	} else if evt.Message.GetExtendedTextMessage() != nil {
		text = evt.Message.GetExtendedTextMessage().GetText()
	}

	if text != "" {
		sendEvent(BridgeEvent{
			Type:     "message",
			ChatID:   evt.Info.Chat.String(),
			SenderID: evt.Info.Sender.String(),
			Text:     text,
			IsGroup:  evt.Info.IsGroup,
		})
	}
}

func sendEvent(event BridgeEvent) {
	data, _ := json.Marshal(event)
	fmt.Println(string(data))
}
