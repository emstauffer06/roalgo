--!strict
-- Decorative native-state view. Enlarged markers track existing measured bodies.
-- No BaseParts, constraints, forces, motion writes, or physics-step selection changes.
local Mechanics=require(script.Parent.Mechanics)
local PhysicsView={}
local COLORS={Color3.fromRGB(72,214,169),Color3.fromRGB(255,194,95),Color3.fromRGB(105,160,255)}
local FOLDER_NAME="RoAlgoMarketPhysicsVisuals"
-- Channel order follows Features:info().driveNames; each node still mixes several inputs.
local DRIVE_MEANINGS={"trend","return","range activity","ETF volume","QQQ minus SPY","IWM minus SPY","TLT return","XLK minus SPY","XLF minus SPY","XLE minus SPY","target daily return","regime stress"}
local GROUP_MEANINGS={"Tape","Equity relative","Sectors / bonds","Participation / regime"}

local function nodeLabel(parent: Instance,rig: Model,node: BasePart,metadata: any,color: Color3)
	local dominant,weight=1,0
	for channel,value in metadata.projection do
		if math.abs(value)>weight then dominant=channel;weight=math.abs(value) end
	end
	local label=Instance.new("BillboardGui")
	label.Name=string.format("NodeLabel%02d",metadata.index);label.Adornee=node
	label.AlwaysOnTop=true;label.LightInfluence=0;label.MaxDistance=0
	label.Size=UDim2.fromOffset(180,58);label.StudsOffsetWorldSpace=Vector3.new(0,30,0);label.SizeOffset=Vector2.new(0,0.5)
	label:SetAttribute("VisualOnly",true);label:SetAttribute("DominantDriveChannel",dominant)
	label:SetAttribute("InputMeaning",DRIVE_MEANINGS[dominant]);label.Parent=parent
	label:SetAttribute("BankMeaning",metadata.bankName);label:SetAttribute("FinancialGroup",metadata.groupName)
	label:SetAttribute("FixedSignedProjection",node:GetAttribute("FixedSignedProjection"))
	local card=Instance.new("Frame")
	card.Name="NodeCard";card.Size=UDim2.fromScale(1,1)
	card.BackgroundColor3=Color3.fromRGB(10,15,24);card.BackgroundTransparency=0;card.BorderSizePixel=0;card.Parent=label
	local corner=Instance.new("UICorner");corner.CornerRadius=UDim.new(0,4);corner.Parent=card
	local border=Instance.new("UIStroke");border.Color=color;border.Thickness=1.5;border.Transparency=0;border.Parent=card
	local title=Instance.new("TextLabel")
	title.Name="NodeIdentity";title.Size=UDim2.new(1,-8,0,18);title.Position=UDim2.fromOffset(4,1)
	title.BackgroundTransparency=1;title.TextColor3=color;title.TextTransparency=0
	title.Font=Enum.Font.GothamBold;title.TextSize=13
	title.Text=string.format("%s · %s · %02d",if rig.Name=="Coupled" then "C" else "I",metadata.bankName,metadata.index);title.Parent=card
	local group=Instance.new("TextLabel")
	group.Name="FinancialGroupMeaning";group.Size=UDim2.new(1,-8,0,17);group.Position=UDim2.fromOffset(4,19)
	group.BackgroundTransparency=1;group.TextColor3=color;group.TextTransparency=0
	group.Font=Enum.Font.GothamMedium;group.TextSize=11;group.Text=GROUP_MEANINGS[metadata.group];group.Parent=card
	local meaning=Instance.new("TextLabel")
	meaning.Name="MixedDriveMeaning";meaning.Size=UDim2.new(1,-8,0,17);meaning.Position=UDim2.fromOffset(4,37)
	meaning.BackgroundTransparency=1;meaning.TextColor3=Color3.fromRGB(240,245,250);meaning.TextTransparency=0
	meaning.Font=Enum.Font.GothamMedium;meaning.TextSize=11;meaning.Text=string.format("mix %+.2f: %s",metadata.projection[dominant],DRIVE_MEANINGS[dominant]);meaning.Parent=card
end

local function physicsCounts(model: Model): any
	local counts={baseParts=0,constraints=0,forces=0}
	for _,item in model:GetDescendants() do
		if item:IsA("BasePart")then counts.baseParts+=1 end
		if item:IsA("Constraint")then counts.constraints+=1 end
		if item:IsA("VectorForce")then counts.forces+=1 end
	end
	return counts
end

function PhysicsView.mount(model: Model): any
	assert(typeof(model)=="Instance" and model:IsA("Model"),"PhysicsView: native Engine model required")
	local coupled=model:FindFirstChild("Coupled")
	local independent=model:FindFirstChild("Independent")
	assert(coupled and coupled:IsA("Model") and independent and independent:IsA("Model"),"PhysicsView: both native rigs required")
	local prior=model:FindFirstChild(FOLDER_NAME)
	if prior then
		assert(prior:IsA("Folder") and prior:GetAttribute("DecorativePhysicsView")==true,"PhysicsView: visual folder name collision")
		prior:Destroy()
	end
	local before=physicsCounts(model)
	local folder=Instance.new("Folder")
	folder.Name=FOLDER_NAME;folder:SetAttribute("DecorativePhysicsView",true)
	folder:SetAttribute("MarkerRadiusStuds",12);folder:SetAttribute("CouplingBeamWidthStuds",4)
	folder:SetAttribute("Scope","Enlarged visual markers follow measured native bodies; decoration never participates in dynamics")
	folder.Parent=model
	local counts={markers=0,couplingBeams=0,axialBeams=0,labels=0,nodeLabels=0,basePartsAdded=0,constraintsAdded=0}
	local ok,err=pcall(function()
		local config=Mechanics.config({nodeCount=model:GetAttribute("NodeCount"),topology=model:GetAttribute("Topology"),response=model:GetAttribute("Response")})
		for _,rig in {coupled,independent}do
			local visualRig=Instance.new("Folder");visualRig.Name=rig.Name;visualRig.Parent=folder
			local nodes: {BasePart}={}
			local couplingCount=0
			for _,item in rig:GetDescendants()do
				if item:IsA("BasePart") and type(item:GetAttribute("NodeIndex"))=="number"then
					table.insert(nodes,item)
					local bank=item:GetAttribute("Bank")
					local color=COLORS[if type(bank)=="number"then bank else 1]or COLORS[1]
					local marker=Instance.new("SphereHandleAdornment")
					marker.Name=string.format("MeasuredNode%02d",item:GetAttribute("NodeIndex"))
					marker.Adornee=item;marker.Radius=12;marker.Color3=color;marker.Transparency=0.12
					marker.AlwaysOnTop=false;marker.ZIndex=1;marker.CFrame=CFrame.identity
					marker:SetAttribute("VisualOnly",true);marker.Parent=visualRig
					counts.markers+=1
					local metadata=config.nodes[item:GetAttribute("NodeIndex")]
					assert(metadata,"PhysicsView: node projection metadata missing")
					nodeLabel(visualRig,rig,item,metadata,color);counts.nodeLabels+=1
				elseif item:IsA("SpringConstraint") and item.Attachment0 and item.Attachment1 then
					local isCoupling=string.sub(item.Name,1,6)=="Couple"
					local a,b=item.Attachment0.Parent,item.Attachment1.Parent
					local bankA=a and a:GetAttribute("Bank")
					local bankB=b and b:GetAttribute("Bank")
					bankA=bankA or bankB;bankB=bankB or bankA
					local colorA=COLORS[if type(bankA)=="number"then bankA else 1]or COLORS[1]
					local colorB=COLORS[if type(bankB)=="number"then bankB else 1]or colorA
					local beam=Instance.new("Beam")
					beam.Name="Visual_"..item.Name;beam.Attachment0=item.Attachment0;beam.Attachment1=item.Attachment1
					beam.Width0=if isCoupling then 4 else 2;beam.Width1=beam.Width0
					beam.FaceCamera=true;beam.Segments=1;beam.LightEmission=0.5;beam.LightInfluence=0
					beam.Color=ColorSequence.new(colorA,colorB)
					beam.Transparency=NumberSequence.new(if isCoupling then 0.10 else 0.65)
					beam:SetAttribute("VisualOnly",true);beam.Parent=visualRig
					if isCoupling then couplingCount+=1;counts.couplingBeams+=1 else counts.axialBeams+=1 end
				end
			end
			table.sort(nodes,function(a,b)return a:GetAttribute("NodeIndex")<b:GetAttribute("NodeIndex")end)
			assert(#nodes>0,"PhysicsView: native nodes missing")
			-- Anchor the label to an existing fixed guide, above the grid's rest geometry.
			local guide=rig:FindFirstChild("Guide1")
			assert(guide and guide:IsA("BasePart"),"PhysicsView: fixed guide missing")
			local sum=Vector3.zero;local topY=-math.huge
			for _,node in nodes do
				local fixed=rig:FindFirstChild("Guide"..tostring(node:GetAttribute("NodeIndex")))
				assert(fixed and fixed:IsA("BasePart"),"PhysicsView: fixed guide missing")
				sum+=fixed.Position;topY=math.max(topY,fixed.Position.Y)
			end
			local center=sum/#nodes
			local label=Instance.new("BillboardGui")
			label.Name=rig.Name.."NativeLabel";label.Adornee=guide;label.AlwaysOnTop=true;label.LightInfluence=0
			label.Size=UDim2.fromOffset(550,32);label.MaxDistance=0
			local captionLift=if rig.Name=="Coupled" then 320 else 180
			label.StudsOffsetWorldSpace=Vector3.new(center.X,topY+captionLift,center.Z)-guide.Position
			label.Parent=visualRig
			local text=Instance.new("TextLabel")
			text.Name="TruthfulMechanicsCaption";text.Size=UDim2.fromScale(1,1)
			text.BackgroundColor3=Color3.fromRGB(10,15,24);text.BackgroundTransparency=0
			text.BorderSizePixel=0;text.TextColor3=Color3.fromRGB(231,240,246)
			text.Font=Enum.Font.GothamMedium;text.TextSize=14;text.TextWrapped=true
			text.Text=string.format("%s · %d native nodes · %d springs · %s / %s",string.upper(rig.Name),#nodes,couplingCount,config.topology,config.response)
			text.Parent=label
			local corner=Instance.new("UICorner");corner.CornerRadius=UDim.new(0,8);corner.Parent=text
			counts.labels+=1
			visualRig:SetAttribute("MeasuredNodes",#nodes);visualRig:SetAttribute("CouplingSprings",couplingCount)
			visualRig:SetAttribute("NodeLabels",#nodes)
		end
		local after=physicsCounts(model)
		assert(after.baseParts==before.baseParts and after.constraints==before.constraints and after.forces==before.forces,
			"PhysicsView: physics inventory must remain unchanged")
		folder:SetAttribute("Markers",counts.markers);folder:SetAttribute("CouplingBeams",counts.couplingBeams)
		folder:SetAttribute("AxialBeams",counts.axialBeams);folder:SetAttribute("Labels",counts.labels)
		folder:SetAttribute("NodeLabels",counts.nodeLabels)
	end)
	if not ok then folder:Destroy();error(tostring(err),2)end
	local view={folder=folder,counts=counts,physicsBefore=before,destroyed=false}
	function view:destroy()if self.destroyed then return end;self.destroyed=true;self.folder:Destroy()end
	return view
end
return PhysicsView
