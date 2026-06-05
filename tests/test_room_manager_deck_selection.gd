class_name TestRoomManagerDeckSelection
extends TestBase


class FakeCardDatabase extends Node:
	var decks_by_id: Dictionary = {}

	func get_deck(deck_id: int) -> DeckData:
		return decks_by_id.get(deck_id)


func test_room_manager_prefers_local_draft_payload_when_deck_id_collides() -> String:
	var sent_messages: Array = []
	var card_db := FakeCardDatabase.new()
	var published_deck := DeckData.from_dict({
		"id": 101,
		"deck_name": "Published Collision Deck",
		"cards": [],
		"total_cards": 60,
	})
	card_db.decks_by_id[101] = published_deck

	var manager := RoomManager.new()
	manager.setup(func(peer_id: int, message: Dictionary) -> void:
		sent_messages.append({
			"peer_id": peer_id,
			"message": message,
		})
	, card_db)

	var room := GameRoom.new()
	room.room_id = "room-1"
	room._card_db = card_db
	room.add_player(11, 0, "玩家A", "token-a")
	manager._rooms[room.room_id] = room

	var session := PlayerSession.new()
	session.peer_id = 11
	session.player_name = "玩家A"
	session.room_id = room.room_id
	session.player_index = 0
	session.session_token = "token-a"
	manager._player_sessions[11] = session

	var local_draft := {
		"id": 101,
		"deck_name": "Local Draft Deck",
		"cards": [],
		"total_cards": 60,
	}
	manager.handle_message(11, NetProtocol.make_message(NetProtocol.MSG_SELECT_DECK, {
		"deck_id": 101,
		"deck_source": NetProtocol.DECK_SOURCE_LOCAL_DRAFT,
		"deck_data": local_draft,
	}))

	return run_checks([
		assert_eq(int(room._players[0].get("deck_id", -1)), 101, "房间应记录当前玩家选择的 deck_id"),
		assert_eq(str(room._extra_deck_data.get(0, {}).get("deck_name", "")), "Local Draft Deck", "本地草稿来源应优先写入房间临时 deck_data"),
		assert_eq(sent_messages.size(), 0, "deck_id 冲突时本地草稿选择不应触发 deck_not_found 错误"),
	])