# GemRB - Infinity Engine Emulator
# Copyright (C) 2003 The GemRB Project
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#


# MessageWindow.py - scripts and GUI for main (walk) window
# Enhanced layout for TrimUI Brick handheld (640x480)

###################################################

import GemRB
import ActionsWindow as ActionsWindowModule
import GUIClasses
import GUICommon
import GUICommonWindows
import CommonWindow
import GUIWORLD
import Clock
import PortraitWindow
from GameCheck import MAX_PARTY_SIZE
from GUIDefines import *

MWindow = 0

def OnDialogWindowClose():
	"""OnClose callback: restore UI bars whenever MWindow closes (Esc, button, etc)."""
	for i in range(3):
		v = GemRB.GetView("NOT_DLG", i)
		if v:
			v.SetFlags(IE_GUI_VIEW_INVISIBLE, OP_NAND)

def OnLoad():
	global MWindow

	ActionsWindow = GemRB.LoadWindow(0, GUICommon.GetWindowPack(), WINDOW_BOTTOM|WINDOW_LEFT)
	ActionsWindow.AddAlias("ACTWIN")
	ActionsWindow.AddAlias("NOT_DLG", 0)
	ActionsWindow.SetFlags(WF_BORDERLESS|IE_GUI_VIEW_IGNORE_EVENTS, OP_OR)

	OptionsWindow = GemRB.LoadWindow(2, GUICommon.GetWindowPack(), WINDOW_BOTTOM|WINDOW_RIGHT)
	OptionsWindow.AddAlias("OPTWIN")
	OptionsWindow.AddAlias("NOT_DLG", 1)
	OptionsWindow.SetFlags(WF_BORDERLESS|IE_GUI_VIEW_IGNORE_EVENTS, OP_OR)

	MWindow = GemRB.LoadWindow(7, GUICommon.GetWindowPack(), WINDOW_BOTTOM|WINDOW_HCENTER)
	MWindow.SetFlags(WF_DESTROY_ON_CLOSE, OP_NAND)
	MWindow.AddAlias("MSGWIN")
	MWindow.AddAlias("HIDE_CUT", 0)
	MWindow.SetFlags(WF_BORDERLESS|IE_GUI_VIEW_IGNORE_EVENTS, OP_OR)
	MWindow.OnClose(OnDialogWindowClose)

	PortraitWin = PortraitWindow.OpenPortraitWindow (WINDOW_BOTTOM|WINDOW_HCENTER)
	PortraitWin.AddAlias("NOT_DLG", 2)
	PortraitWin.SetFlags(WF_BORDERLESS|IE_GUI_VIEW_IGNORE_EVENTS, OP_OR)

	pframe = PortraitWin.GetFrame()
	pframe['x'] -= 16
	PortraitWin.SetFrame(pframe)

	# --- Get controls ---
	MessageTA = MWindow.GetControl(1)
	CloseButton = MWindow.GetControl(0)
	GoldLabel = MWindow.GetControl(0x10000003)

	# --- Dialogue window: 60% of screen height ---
	TARGET_H = 288
	mf = MWindow.GetFrame()
	mf['y'] = 480 - TARGET_H
	mf['h'] = TARGET_H
	mf['x'] = 0
	mf['w'] = 640
	MWindow.SetFrame(mf)

	# Replace MOS background with dark semi-transparent fill
	MWindow.SetBackground({'r': 0, 'g': 0, 'b': 0, 'a': 144})

	# --- TextArea: fill full window height ---
	TA_MARGIN = 12
	MessageTA.SetFlags(IE_GUI_TEXTAREA_AUTOSCROLL|IE_GUI_TEXTAREA_HISTORY)
	MessageTA.SetResizeFlags(IE_GUI_VIEW_RESIZE_ALL)
	MessageTA.AddAlias("MsgSys", 0)
	MessageTA.SetFrame({'x': TA_MARGIN, 'y': TA_MARGIN, 'w': 640 - TA_MARGIN * 2, 'h': TARGET_H - TA_MARGIN * 2})

	# Text margins — uniform padding inside text area
	MessageTA.SetMargins(16, 16, 16, 4)

	# Colors - warm tones on dark background
	MessageTA.SetColor({'r': 200, 'g': 200, 'b': 200, 'a': 255}, TA_COLOR_NORMAL)    # light grey for NPC text
	MessageTA.SetColor({'r': 180, 'g': 220, 'b': 255, 'a': 255}, TA_COLOR_OPTIONS)   # soft blue for options
	MessageTA.SetColor({'r': 255, 'g': 255, 'b': 180, 'a': 255}, TA_COLOR_HOVER)     # warm yellow hover
	MessageTA.SetColor({'r': 0, 'g': 0, 'b': 0, 'a': 0}, TA_COLOR_BACKGROUND)        # transparent bg

	# --- Gold label: gold text, top-right ---
	GoldLabel.SetFrame({'x': 548, 'y': 4, 'w': 76, 'h': 18})
	GoldLabel.SetColor({'r': 255, 'g': 215, 'b': 0, 'a': 255})

	# --- Close/Continue button: top-left corner ---
	CloseButton.SetSprites("", 0, 0, 0, 0, 0)
	CloseButton.SetFrame({'x': 0, 'y': 0, 'w': 200, 'h': 20})
	CloseButton.SetBackground({'r': 30, 'g': 30, 'b': 40, 'a': 200})
	CloseButton.SetBorder(0, {'r': 140, 'g': 160, 'b': 180, 'a': 160}, 1, 0)
	CloseButton.SetColor({'r': 180, 'g': 200, 'b': 220, 'a': 255})
	CloseButton.SetText(28082)
	CloseButton.OnPress(MWindow.Close)
	CloseButton.MakeDefault()

	# Z-order fix: move button in front of TextArea so it gets hit-tested first
	MWindow.AddSubview(CloseButton, MessageTA)

	# Scrollbar - thin (8px), starts below gold label on the right
	sb = MessageTA.GetScrollBar()
	if sb:
		taf = MessageTA.GetFrame()
		gf = GoldLabel.GetFrame()
		sb_w = 12
		sb_y = gf['y'] + gf['h'] + 2
		sb.SetFrame({'x': taf['w'] - sb_w - 2, 'y': sb_y, 'w': sb_w, 'h': TARGET_H - TA_MARGIN * 2 - sb_y - 2})

	OpenButton = OptionsWindow.GetControl(10)
	OpenButton.OnPress(MWindow.Focus)

	SetupClockWindowControls(ActionsWindow)
	GUICommonWindows.SetupMenuWindowControls(OptionsWindow)

	UpdateControlStatus()

def SetupClockWindowControls (Window):
	# time button
	Button = Window.GetControl (0)
	Clock.CreateClockButton(Button)

	# 41627 - Return to the Game World
	Button = Window.GetControl (2)
	Button.OnPress (GUICommonWindows.CloseTopWindow)
	Button.SetTooltip (41627)

	# Select all characters
	Button = Window.GetControl (1)
	Button.SetTooltip (41659)
	Button.OnPress (GUICommon.SelectAllOnPress)

	# Abort current action
	Button = Window.GetControl (3)
	Button.SetTooltip (41655)
	Button.OnPress (ActionsWindowModule.ActionStopPressed)

	# Formations
	import GUIWORLD
	Button = Window.GetControl (4)
	Button.SetTooltip (44945)
	Button.OnPress (GUIWORLD.OpenFormationWindow)

	return

def UpdateControlStatus ():
	if GemRB.GetGUIFlags() & (GS_DIALOGMASK|GS_DIALOG):
		Label = MWindow.GetControl(0x10000003)
		Label.SetText(str(GemRB.GameGetPartyGold()))

		# Hide NOT_DLG windows (portrait bar, action bar, options bar)
		# so they don't render on top of our full-width dialogue window
		for i in range(3):
			v = GemRB.GetView("NOT_DLG", i)
			if v:
				v.SetFlags(IE_GUI_VIEW_INVISIBLE, OP_OR)

		# Enable keyboard events — focus scrollbar (it CAN lock focus, unlike ScrollView)
		MWindow.SetFlags(IE_GUI_VIEW_IGNORE_EVENTS, OP_NAND)
		MessageTA = MWindow.GetControl(1)
		MessageTA.SetFlags(IE_GUI_VIEW_IGNORE_EVENTS, OP_NAND)
		MWindow.Focus()
		sb = MessageTA.GetScrollBar()
		if sb:
			sb.Focus()
		else:
			MessageTA.Focus()
	elif MWindow:
		# Restore NOT_DLG windows
		for i in range(3):
			v = GemRB.GetView("NOT_DLG", i)
			if v:
				v.SetFlags(IE_GUI_VIEW_INVISIBLE, OP_NAND)

		MWindow.SetFlags(IE_GUI_VIEW_IGNORE_EVENTS, OP_OR)
		MWindow.Close()
