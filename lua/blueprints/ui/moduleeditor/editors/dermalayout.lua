if SERVER then AddCSLuaFile() return end

module("editor_dermalayout", package.seeall, bpcommon.rescope(bpschema))

local EDITOR = {}

EDITOR.HasSideBar = true
EDITOR.HasDetails = true
EDITOR.CanExportLuaScript = true

function EDITOR:Setup()

end

function EDITOR:PopulateMenuBar( t )

	BaseClass.PopulateMenuBar(self, t)

	--[[if not self.editingModuleTab then
		t[#t+1] = { name = "New SubModule", func = function() self:NewSubModule() end, icon = "icon16/asterisk_yellow.png" }
	end]]

	--t[#t+1] = { name = "Toggle Design Mode", func = function() self:ToggleDesignMode() end, color = Color(120,60,90) }

end

function EDITOR:ToggleDesignMode()

end

function EDITOR:LayoutChanged()

	self:BuildNodeTree()
	self:CreatePanel()

end

function EDITOR:OpenDetails( node )

	self.detailsBar:Clear()

	self.detailsBar:Add( "Details" ):SetContents( node:GetEdit():CreateVGUI({ live = true, }) )

	if node:GetLayout() then

		self.detailsBar:Add( "Layout" ):SetContents( node:GetLayout():GetEdit():CreateVGUI({ live = true, }) )

	end

end

function EDITOR:NodeSelected(node)

	self:OpenDetails(node)

end

function EDITOR:NodeContextMenu(node, vnode)

	if IsValid(self.cmenu) then self.cmenu:Remove() end
	self.cmenu = DermaMenu( false, self:GetPanel() )

	print(tostring(node.CanHaveChildren))

	if node.CanHaveChildren then

		-- Enumerate child node classes
		local addChildMenu, op = self.cmenu:AddSubMenu( tostring( LOCTEXT"layout_submenu_addchild","Add Child" ) )
		local loader = bpdermanode.GetClassLoader()
		local classes = bpcommon.Transform( loader:GetClasses(), {}, function(k) return {name = k, class = loader:Get(k)} end )

		table.sort( classes, function(a,b) return tostring(a.class.Name) < tostring(b.class.Name) end )

		for _, v in ipairs( classes ) do

			local cl = v.class
			if cl.RootOnly then continue end
			if not cl.Creatable then continue end

			local op = addChildMenu:AddOption( tostring(cl.Name), function()
				local newNode = bpdermanode.New(v.name, node)
				newNode:SetupDefaultLayout()
				self:LayoutChanged()
			end )
			if cl.Icon then op:SetIcon( cl.Icon ) end
			if cl.Description then op:SetTooltip( tostring(cl.Description) ) end

		end

		-- Enumerate layout classes
		local setLayoutMenu, op = self.cmenu:AddSubMenu( tostring( LOCTEXT"layout_submenu_setlayout","Set Layout" ) )
		local loader = bplayout.GetClassLoader()
		local classes = bpcommon.Transform( loader:GetClasses(), {}, function(k) return {name = k, class = loader:Get(k)} end )

		table.sort( classes, function(a,b) return tostring(a.class.Name) < tostring(b.class.Name) end )

		setLayoutMenu:AddOption( tostring( LOCTEXT"layout_submenu_layoutnone","No Layout" ), function()
			node:SetLayout(nil)
			self:LayoutChanged()
		end ):SetIcon( "icon16/cut.png" )

		for _, v in ipairs( classes ) do

			local cl = v.class
			if not cl.Creatable then continue end

			local op = setLayoutMenu:AddOption( tostring(cl.Name), function()
				local newLayout = bplayout.New(v.name)
				node:SetLayout(newLayout)
				self:LayoutChanged()
			end )
			if cl.Icon then op:SetIcon( cl.Icon ) end
			if cl.Description then op:SetTooltip( tostring(cl.Description) ) end

		end

	end

	if node:GetParent() ~= nil then
		self.cmenu:AddOption( tostring( LOCTEXT"layout_submenu_delete","Delete" ), function()
			node:GetParent():RemoveChild( node )
			self:LayoutChanged()
		end ):SetIcon( "icon16/delete.png" )
	end

	self.cmenu:Open( gui.MouseX(), gui.MouseY(), false, self:GetPanel() )

end

function EDITOR:CreatePanel()

	self:DestroyPanel()

	local ok, res = self:GetModule():TryBuild( bit.bor(bpcompiler.CF_Debug, bpcompiler.CF_ILP, bpcompiler.CF_CompactVars) )
	if ok then
		local ok, lres = res:TryLoad()
		if ok then

			local unit = res:Get()
			self.preview = unit.create()

			if IsValid(self.preview) then
				self.preview:SetPaintedManually(true)
				self.preview:Hide()

				self:GetModule():Root():MapToPreview( self.preview )

				if IsValid(self.vpreview) then self.vpreview:SetPanel( self.preview ) end
			end

		else

			print("Load failure: " .. tostring(lres))

		end
	else

		print("Compile failure: " .. tostring(res))

	end

end

function EDITOR:DestroyPanel()

	if IsValid( self.preview ) then
		self.preview:Remove()
	end

end

function EDITOR:PostInit()

	self:CreatePanel()

	self.vpreview = vgui.Create("BPDPreview")
	self.vpreview:SetPanel( self.preview )
	self:SetContent( self.vpreview )

	self.detailsBar = vgui.Create("BPCategoryList")
	self:SetDetails( self.detailsBar )

end

function EDITOR:Shutdown()

	self:DestroyPanel()
	if IsValid(self.cmenu) then self.cmenu:Remove() end

end

function EDITOR:Think()

end

function EDITOR:PopulateSideBar()

	self.hierarchyPanel = vgui.Create("DPanel")
	self.hierarchyPanel:SetSize(100,200)
	self.hierarchyPanel:SetMinimumSize(100,200)
	self.hierarchyPanel:SetBackgroundColor(Color(40,40,40))

	self.hierarchyTree = vgui.Create("DTree", self.hierarchyPanel)
	self.hierarchyTree:Dock( FILL )
	self.hierarchyTree:SetClickOnDragHover(true)

	self.hierarchyBar = self:AddSidebarPanel(LOCTEXT("editor_dermalayout_hierarchy","Hierarchy"), self.hierarchyPanel)

	self.callbackList = self:AddSidebarList(LOCTEXT("editor_dermalayout_callbacks","Callbacks"))
	self.callbackList.HandleAddItem = function(pnl, list)

	end

	self:BuildNodeTree()

end

function EDITOR:RecursiveAddNode(vnode, node)

	local newNode = vnode:AddNode(node:GetName(), node.Icon or "icon16/application.png")
	newNode:SetExpanded(true)
	newNode.node = node

	if not node.RootOnly then
		newNode:Droppable("dermanode")
	end

	newNode:Receiver( "dermanode", function( pnl, panels, isDropped, menuIndex, mouseX, mouseY )
		if isDropped then
			local changed = false
			for _, src in ipairs(panels) do
				if src.node == pnl.node then continue end
				src.node:GetParent():RemoveChild( src.node )
				pnl.node:AddChild(src.node)
				changed = true
			end
			if changed then self:LayoutChanged() end
		end
	end )

	newNode.DoClick = function()
		self:NodeSelected( node )
	end
	newNode.DoRightClick = function()
		self:NodeContextMenu( node, newNode )
	end
	for _, child in ipairs(node:GetChildren()) do
		self:RecursiveAddNode( newNode, child )
	end

end

function EDITOR:BuildNodeTree()

	self.hierarchyTree:Clear()

	local rootNode = self:GetModule():Root()
	local root = self.hierarchyTree:Root()

	if not rootNode then return end

	self:RecursiveAddNode( root, rootNode )

end

RegisterModuleEditorClass("dermalayout", EDITOR, "basemodule")